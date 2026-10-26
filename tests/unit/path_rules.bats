#!/usr/bin/env bats
# Unit tests of the path rules that decide which host paths are visible in the
# sandbox: pattern expansion (find_matches), whitelist binds, blacklist
# tmpfs/dev-null overlays, `!` overrides and the helpers around them.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    BWRAP_ARGS=()
    WHITELIST_OVERRIDE_ARGS=()
    BLACKLISTED_DIRS=()
    BLACKLIST_SEARCH_ROOTS=("$WORKING_DIR")
    LOG_FILE="$BATS_TEST_TMPDIR/log"
}

# Usage: make_files <path...>; creates files (and their parent directories)
# below TEST_WORK
make_files() {
    local f
    for f in "$@"; do
        mkdir -p "$(dirname "$TEST_WORK/$f")"
        : > "$TEST_WORK/$f"
    done
}

# Usage: assert_matches <base> <pattern> <expected relative paths...>
# Compares the sorted find_matches output with the expected paths (relative to
# <base>, "." for the base itself).
assert_matches() {
    local base="$1" pattern="$2"
    shift 2
    local expected="" p
    if [[ $# -gt 0 ]]; then
        expected=$(for p in "$@"; do
            if [[ "$p" == . ]]; then echo "$base"; else echo "$base/$p"; fi
        done | sort)
    fi
    run bash -c 'source "$1"; set +u; find_matches "$2" "$3" | sort' _ \
        "$SANDBOX_SCRIPT" "$base" "$pattern"
    assert_success
    assert_output "$expected"
}

# --- find_matches ---------------------------------------------------------------

@test "find_matches: an empty pattern returns the base directory itself" {
    assert_matches "$TEST_WORK" "" .
}

@test "find_matches: a simple glob only matches the first level" {
    make_files a.env .env b.txt sub/c.env
    assert_matches "$TEST_WORK" "*.env" a.env .env
}

@test "find_matches: dir/* matches the entries of dir" {
    make_files dir/a dir/b other/c
    assert_matches "$TEST_WORK" "dir/*" dir/a dir/b
}

@test "find_matches: a glob after a directory does not cross further directories" {
    skip "BUG: '*' in non-ant patterns crosses '/', so data/*/config.json also matches data/a/b/config.json (whitelist over-exposure)"
    make_files data/a/config.json data/a/b/config.json
    assert_matches "$TEST_WORK" "data/*/config.json" data/a/config.json
}

@test "find_matches: **/name matches at every depth including the first level" {
    make_files wallet.dat a/wallet.dat a/b/c/wallet.dat a/other.dat
    assert_matches "$TEST_WORK" "**/wallet.dat" wallet.dat a/wallet.dat a/b/c/wallet.dat
}

@test "find_matches: **/name matches directories too" {
    mkdir -p "$TEST_WORK/.secrets" "$TEST_WORK/x/y/.secrets"
    assert_matches "$TEST_WORK" "**/.secrets" .secrets x/y/.secrets
}

@test "find_matches: **/dir/file lets **/ match zero directories" {
    make_files conf/secret.json a/conf/secret.json a/b/conf/secret.json conf/other.json a/secret.json
    assert_matches "$TEST_WORK" "**/conf/secret.json" \
        conf/secret.json a/conf/secret.json a/b/conf/secret.json
}

@test "find_matches: every **/ in src/**/test/**/*.java may match zero directories" {
    make_files \
        src/test/A.java \
        src/main/test/B.java \
        src/test/pkg/C.java \
        src/x/y/test/p/q/D.java \
        src/main/E.java \
        src/test/F.kt \
        other/test/G.java
    assert_matches "$TEST_WORK" "src/**/test/**/*.java" \
        src/test/A.java src/main/test/B.java src/test/pkg/C.java src/x/y/test/p/q/D.java
}

@test "find_matches: a trailing ** matches everything below the directory" {
    make_files data/a data/sub/b
    assert_matches "$TEST_WORK" "data/**" data/a data/sub data/sub/b
}

@test "find_matches: patterns without matches return nothing and succeed" {
    make_files a.txt
    assert_matches "$TEST_WORK" "*.env"
    assert_matches "$TEST_WORK" "**/nothing"
    assert_matches "$TEST_WORK" "nope/*"
    assert_matches "$TEST_WORK" "**/x/**/y"
}

@test "find_matches: names with spaces are returned intact" {
    make_files "my dir/secret file.env" "top level.env"
    assert_matches "$TEST_WORK" "*.env" "top level.env"
    assert_matches "$TEST_WORK" "**/secret file.env" "my dir/secret file.env"
    assert_matches "$TEST_WORK" "my dir/*" "my dir/secret file.env"
}

# --- whitelist_path --------------------------------------------------------------

@test "whitelist_path: an absolute directory is bound read-only by default" {
    mkdir -p "$BATS_TEST_TMPDIR/tools"
    whitelist_path "$BATS_TEST_TMPDIR/tools" ro
    assert_equal "${BWRAP_ARGS[*]}" "--ro-bind $BATS_TEST_TMPDIR/tools $BATS_TEST_TMPDIR/tools"
}

@test "whitelist_path: rw mode binds read-write" {
    mkdir -p "$BATS_TEST_TMPDIR/cache"
    whitelist_path "$BATS_TEST_TMPDIR/cache" rw
    assert_args_contain BWRAP_ARGS --bind "$BATS_TEST_TMPDIR/cache" "$BATS_TEST_TMPDIR/cache"
    refute_args_contain BWRAP_ARGS --ro-bind "$BATS_TEST_TMPDIR/cache"
}

@test "whitelist_path: relative paths are resolved against the working directory" {
    make_files data/file.txt
    whitelist_path data ro
    assert_args_contain BWRAP_ARGS --ro-bind "$TEST_WORK/data" "$TEST_WORK/data"
}

@test "whitelist_path: relative matches become blacklist search roots, absolute ones do not" {
    make_files data/file.txt single.txt
    mkdir -p "$BATS_TEST_TMPDIR/abs"
    whitelist_path data ro
    whitelist_path single.txt ro
    whitelist_path "$BATS_TEST_TMPDIR/abs" ro
    assert_equal "${BLACKLIST_SEARCH_ROOTS[*]}" "$TEST_WORK $TEST_WORK/data"
}

@test "whitelist_path: ~ and \$HOME expand to the home directory" {
    mkdir -p "$HOME/.local/bin" "$HOME/.m2"
    whitelist_path '~/.local/bin' ro
    whitelist_path '$HOME/.m2' rw
    assert_args_contain BWRAP_ARGS --ro-bind "$HOME/.local/bin" "$HOME/.local/bin"
    assert_args_contain BWRAP_ARGS --bind "$HOME/.m2" "$HOME/.m2"
}

@test "whitelist_path: an absolute glob binds every match separately" {
    mkdir -p "$BATS_TEST_TMPDIR/etc/java-17" "$BATS_TEST_TMPDIR/etc/java-21" "$BATS_TEST_TMPDIR/etc/other"
    whitelist_path "$BATS_TEST_TMPDIR/etc/java*" ro
    assert_args_contain BWRAP_ARGS --ro-bind "$BATS_TEST_TMPDIR/etc/java-17" "$BATS_TEST_TMPDIR/etc/java-17"
    assert_args_contain BWRAP_ARGS --ro-bind "$BATS_TEST_TMPDIR/etc/java-21" "$BATS_TEST_TMPDIR/etc/java-21"
    refute_args_contain BWRAP_ARGS --ro-bind "$BATS_TEST_TMPDIR/etc/other"
    assert_equal "${#BWRAP_ARGS[@]}" 6
}

@test "whitelist_path: absolute ant patterns match at any depth" {
    local base="$BATS_TEST_TMPDIR/usr"
    mkdir -p "$base/lib64" "$base/a/b/lib64" "$base/a/lib"
    whitelist_path "$base/**/lib64" ro
    assert_args_contain BWRAP_ARGS --ro-bind "$base/lib64" "$base/lib64"
    assert_args_contain BWRAP_ARGS --ro-bind "$base/a/b/lib64" "$base/a/b/lib64"
    refute_args_contain BWRAP_ARGS --ro-bind "$base/a/lib"
}

@test "whitelist_path: relative ant patterns match below the working directory" {
    make_files src/a.json src/deep/b.json src/c.txt
    whitelist_path 'src/**/*.json' rw
    assert_args_contain BWRAP_ARGS --bind "$TEST_WORK/src/a.json" "$TEST_WORK/src/a.json"
    assert_args_contain BWRAP_ARGS --bind "$TEST_WORK/src/deep/b.json" "$TEST_WORK/src/deep/b.json"
    refute_args_contain BWRAP_ARGS --bind "$TEST_WORK/src/c.txt"
}

@test "whitelist_path: a non-existent path is skipped with a warning" {
    run whitelist_path "$BATS_TEST_TMPDIR/missing" ro
    assert_success
    assert_output --partial "No matches for pattern: $BATS_TEST_TMPDIR/missing"
    whitelist_path "$BATS_TEST_TMPDIR/missing" ro 2>/dev/null
    assert_equal "${#BWRAP_ARGS[@]}" 0
}

@test "whitelist_path: a pattern without matches is skipped with a warning" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run whitelist_path "$BATS_TEST_TMPDIR/empty/*.conf" ro
    assert_success
    assert_output --partial "No matches for pattern"
}

@test "whitelist_path: paths with spaces are bound as single arguments" {
    mkdir -p "$BATS_TEST_TMPDIR/with space"
    whitelist_path "$BATS_TEST_TMPDIR/with space" ro
    assert_equal "${#BWRAP_ARGS[@]}" 3
    assert_equal "${BWRAP_ARGS[1]}" "$BATS_TEST_TMPDIR/with space"
}

@test "whitelist_path: writes into the named target array" {
    mkdir -p "$BATS_TEST_TMPDIR/x"
    whitelist_path "$BATS_TEST_TMPDIR/x" ro WHITELIST_OVERRIDE_ARGS "Whitelisted (override)" 2>"$LOG_FILE"
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_equal "${WHITELIST_OVERRIDE_ARGS[*]}" "--ro-bind $BATS_TEST_TMPDIR/x $BATS_TEST_TMPDIR/x"
    run cat "$LOG_FILE"
    assert_output --partial "Whitelisted (override): $BATS_TEST_TMPDIR/x"
}

# --- blacklist_pattern -----------------------------------------------------------

@test "blacklist_pattern: a directory is hidden with tmpfs" {
    mkdir -p "$TEST_WORK/secrets"
    blacklist_pattern secrets
    assert_equal "${BWRAP_ARGS[*]}" "--tmpfs $TEST_WORK/secrets"
    assert_equal "${BLACKLISTED_DIRS[*]}" "$TEST_WORK/secrets"
}

@test "blacklist_pattern: a file is hidden by binding /dev/null over it" {
    make_files .env
    blacklist_pattern .env
    assert_equal "${BWRAP_ARGS[*]}" "--ro-bind /dev/null $TEST_WORK/.env"
}

@test "blacklist_pattern: a trailing slash is ignored" {
    mkdir -p "$TEST_WORK/.trees"
    blacklist_pattern .trees/
    assert_args_contain BWRAP_ARGS --tmpfs "$TEST_WORK/.trees"
}

@test "blacklist_pattern: glob patterns hide every match" {
    make_files a.env b.env keep.txt .secrets/x .secrets/y
    blacklist_pattern '*.env'
    blacklist_pattern '.secrets/*'
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/a.env"
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/b.env"
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/.secrets/x"
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/.secrets/y"
    refute_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/keep.txt"
}

@test "blacklist_pattern: ant patterns hide matches at every depth" {
    make_files .env a/.env a/b/.env a/b/c/keep
    blacklist_pattern '**/.env'
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/.env"
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/a/.env"
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/a/b/.env"
    assert_equal "${#BWRAP_ARGS[@]}" 9
}

@test "blacklist_pattern: matches under an already blacklisted directory are skipped" {
    make_files secret/.env secret/inner/.env
    mkdir -p "$TEST_WORK/secret/inner/secret"
    blacklist_pattern secret
    blacklist_pattern '**/.env' 2>"$LOG_FILE"
    blacklist_pattern '**/secret' 2>>"$LOG_FILE"
    assert_equal "${BWRAP_ARGS[*]}" "--tmpfs $TEST_WORK/secret"
    run cat "$LOG_FILE"
    assert_output --partial "Skipping blacklist for secret/.env (already covered by blacklisted parent dir)"
    assert_output --partial "Skipping blacklist for secret/inner/secret (already covered"
    refute_output --partial "No matches"
}

@test "blacklist_pattern: no match logs a warning and does not fail" {
    run blacklist_pattern 'nothing-*.env'
    assert_success
    assert_output --partial "No matches for pattern: nothing-*.env"
}

@test "blacklist_pattern: names with spaces are hidden" {
    make_files "my dir/secret file.env"
    blacklist_pattern "**/secret file.env"
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/my dir/secret file.env"
}

@test "blacklist_pattern: also searches relative whitelist roots" {
    local outside="$BATS_TEST_TMPDIR/shared"
    mkdir -p "$outside"
    : > "$outside/creds.env"
    # A relative whitelist entry whose match lies outside the working directory
    BLACKLIST_SEARCH_ROOTS+=("$outside")
    blacklist_pattern '*.env'
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$outside/creds.env"
}

@test "blacklist_pattern: a symlink to a file inside the roots hides the target" {
    make_files real/token
    ln -s real/token "$TEST_WORK/token-link"
    blacklist_pattern token-link
    assert_equal "${BWRAP_ARGS[*]}" "--ro-bind /dev/null $TEST_WORK/real/token"
}

@test "blacklist_pattern: a symlink to a directory inside the roots hides the target with tmpfs" {
    mkdir -p "$TEST_WORK/real/keys"
    ln -s real/keys "$TEST_WORK/keys"
    blacklist_pattern keys
    assert_equal "${BWRAP_ARGS[*]}" "--tmpfs $TEST_WORK/real/keys"
    assert_equal "${BLACKLISTED_DIRS[*]}" "$TEST_WORK/real/keys"
}

@test "blacklist_pattern: a symlink pointing outside the roots is skipped with a warning" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$TEST_WORK/out"
    ln -s "$BATS_TEST_TMPDIR/missing" "$TEST_WORK/dangling"
    run blacklist_pattern out
    assert_success
    assert_output --partial "Skipping symlink blacklist for out"
    run blacklist_pattern dangling
    assert_output --partial "Skipping symlink blacklist for dangling"
    blacklist_pattern out 2>/dev/null
    blacklist_pattern dangling 2>/dev/null
    assert_equal "${#BWRAP_ARGS[@]}" 0
}

@test "blacklist_pattern: a leading ./ still hides the path" {
    skip "BUG: './secret.env' is turned into -path WORK/./secret.env, which never matches (only a 'No matches' warning)"
    make_files secret.env
    blacklist_pattern ./secret.env
    assert_args_contain BWRAP_ARGS --ro-bind /dev/null "$TEST_WORK/secret.env"
}

# --- parse_whitelist_override / process_whitelist_entry --------------------------

@test "parse_whitelist_override: plain entries are not overrides" {
    run parse_whitelist_override "/usr/bin"
    assert_output "false /usr/bin"
}

@test "parse_whitelist_override: ! marks an override and strips following spaces" {
    run parse_whitelist_override "!data/keep.env"
    assert_output "true data/keep.env"
    run parse_whitelist_override "!   data/keep.env:rw"
    assert_output "true data/keep.env:rw"
}

@test "process_whitelist_entry: plain entries go to BWRAP_ARGS read-only" {
    mkdir -p "$BATS_TEST_TMPDIR/opt"
    process_whitelist_entry "$BATS_TEST_TMPDIR/opt"
    assert_equal "${BWRAP_ARGS[*]}" "--ro-bind $BATS_TEST_TMPDIR/opt $BATS_TEST_TMPDIR/opt"
    assert_equal "${#WHITELIST_OVERRIDE_ARGS[@]}" 0
}

@test "process_whitelist_entry: the :rw suffix binds read-write" {
    mkdir -p "$BATS_TEST_TMPDIR/opt"
    process_whitelist_entry "$BATS_TEST_TMPDIR/opt:rw"
    assert_equal "${BWRAP_ARGS[*]}" "--bind $BATS_TEST_TMPDIR/opt $BATS_TEST_TMPDIR/opt"
}

@test "process_whitelist_entry: ! entries go to WHITELIST_OVERRIDE_ARGS" {
    make_files secrets/public.pem
    process_whitelist_entry "!secrets/public.pem"
    process_whitelist_entry "! secrets:rw"
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_args_contain WHITELIST_OVERRIDE_ARGS --ro-bind "$TEST_WORK/secrets/public.pem" "$TEST_WORK/secrets/public.pem"
    assert_args_contain WHITELIST_OVERRIDE_ARGS --bind "$TEST_WORK/secrets" "$TEST_WORK/secrets"
}

@test "process_whitelist_entry: an empty entry or a bare ! does nothing" {
    process_whitelist_entry ""
    process_whitelist_entry "!"
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_equal "${#WHITELIST_OVERRIDE_ARGS[@]}" 0
}

@test "override entries re-allow a blacklisted file after the blacklist mount" {
    make_files secrets/private.key secrets/public.pem
    process_whitelist_entry "!secrets/public.pem"
    blacklist_pattern secrets
    # The main section appends the overrides after the blacklist mounts
    BWRAP_ARGS+=("${WHITELIST_OVERRIDE_ARGS[@]}")
    assert_equal "${BWRAP_ARGS[*]}" \
        "--tmpfs $TEST_WORK/secrets --ro-bind $TEST_WORK/secrets/public.pem $TEST_WORK/secrets/public.pem"
    refute_args_contain BWRAP_ARGS --ro-bind "$TEST_WORK/secrets/private.key"
}

# --- is_path_bound / warn_shadowed_binds -----------------------------------------

@test "is_path_bound: matches bind destinations and paths below them" {
    BWRAP_ARGS=(--tmpfs "$HOME" --ro-bind /src/a "$HOME/.local" --bind /src/b /data)
    run is_path_bound "$HOME/.local"
    assert_success
    run is_path_bound "$HOME/.local/share/x"
    assert_success
    run is_path_bound /data
    assert_success
}

@test "is_path_bound: ignores sources, tmpfs mounts and sibling prefixes" {
    BWRAP_ARGS=(--tmpfs "$HOME" --ro-bind /src/a "$HOME/.local" --bind /src/b /data)
    run is_path_bound "$HOME/.localx"
    assert_failure
    run is_path_bound /src/a
    assert_failure
    run is_path_bound "$HOME/other"
    assert_failure
    run is_path_bound /
    assert_failure
}

@test "warn_shadowed_binds: warns about binds at or below the destination only" {
    BWRAP_ARGS=(
        --ro-bind "$HOME/.claude/agents" "$HOME/.claude/agents"
        --bind "$HOME/.claude" "$HOME/.claude"
        --ro-bind "$HOME/.claudex" "$HOME/.claudex"
        --tmpfs "$HOME/.claude/tmp"
    )
    run warn_shadowed_binds "$HOME/.claude"
    assert_success
    assert_line --partial "Mount at $HOME/.claude/agents is shadowed by the profile mount at $HOME/.claude"
    assert_line --partial "Mount at $HOME/.claude is shadowed"
    refute_output --partial ".claudex"
    refute_output --partial ".claude/tmp"
    assert_equal "${#lines[@]}" 2
}

@test "warn_shadowed_binds: silent when nothing is shadowed" {
    BWRAP_ARGS=(--ro-bind /usr /usr)
    run warn_shadowed_binds "$HOME/.claude"
    assert_success
    assert_output ""
}

# --- protect_project_config_dir --------------------------------------------------

@test "protect_project_config_dir: binds .ai-agent-sandbox read-only when present" {
    mkdir -p "$PROJECT_CONFIG_DIR"
    protect_project_config_dir
    assert_equal "${BWRAP_ARGS[*]}" "--ro-bind $TEST_WORK/.ai-agent-sandbox $TEST_WORK/.ai-agent-sandbox"
}

@test "protect_project_config_dir: nothing when the directory does not exist" {
    protect_project_config_dir
    assert_equal "${#BWRAP_ARGS[@]}" 0
}

@test "protect_project_config_dir: nothing when protection is switched off" {
    mkdir -p "$PROJECT_CONFIG_DIR"
    PROTECT_PROJECT_CONFIG=false
    protect_project_config_dir
    assert_equal "${#BWRAP_ARGS[@]}" 0
}

@test "blacklisted files in .ai-agent-sandbox are hidden on top of the read-only bind" {
    mkdir -p "$PROJECT_CONFIG_DIR"
    : > "$PROJECT_CONFIG_DIR/secret.env"
    protect_project_config_dir
    blacklist_pattern '.ai-agent-sandbox/*.env'
    assert_equal "${BWRAP_ARGS[*]}" \
        "--ro-bind $PROJECT_CONFIG_DIR $PROJECT_CONFIG_DIR --ro-bind /dev/null $PROJECT_CONFIG_DIR/secret.env"
}
