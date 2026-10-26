#!/usr/bin/env bats
# Unit tests of the migration of legacy whitelist.txt / blacklist.txt / .env
# files into config.yaml: YAML quoting of list entries, conversion of legacy
# files, merging into an existing top-level block and the staged, all-or-nothing
# migration that renames the sources to *.migrated.

bats_require_minimum_version 1.5.0

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    LEGACY_DIR="$BATS_TEST_TMPDIR/legacy"
    mkdir -p "$LEGACY_DIR"
}

# Usage: write_file <path> <line...>
write_file() {
    local path="$1"
    shift
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$@" > "$path"
}

# Usage: run_migration <config> <config-local>
# Migrate whitelist.txt, blacklist.txt, .env and .env.local from LEGACY_DIR.
run_migration() {
    run migrate_legacy_config "$1" "$2" \
        "$LEGACY_DIR/whitelist.txt" "$LEGACY_DIR/blacklist.txt" \
        "$LEGACY_DIR/.env" "$LEGACY_DIR/.env.local"
}

# --- yaml_list_item -----------------------------------------------------------

@test "yaml_list_item writes safe entries as plain scalars" {
    local item
    for item in /opt/tools '~/.local' '$HOME/bin' data/:rw /opt/x:rw .env /etc/java[0-9]* src/**/*.txt; do
        run yaml_list_item "$item"
        assert_output "- $item"
    done
}

@test "yaml_list_item single-quotes entries that are not safe plain scalars" {
    run yaml_list_item '*.env'
    assert_output "- '*.env'"
    run yaml_list_item '**/wallet.dat'
    assert_output "- '**/wallet.dat'"
    run yaml_list_item '!secrets/allowed'
    assert_output "- '!secrets/allowed'"
    run yaml_list_item 'a#b'
    assert_output "- 'a#b'"
    run yaml_list_item 'key: value'
    assert_output "- 'key: value'"
    run yaml_list_item 'dir:'
    assert_output "- 'dir:'"
    run yaml_list_item '"quoted"'
    assert_output "- '\"quoted\"'"
}

@test "yaml_list_item quotes null-like entries" {
    local item
    for item in '~' null Null NULL; do
        run yaml_list_item "$item"
        assert_output "- '$item'"
    done
}

@test "yaml_list_item doubles single quotes inside a quoted entry" {
    run yaml_list_item "it's"
    assert_output "- 'it''s'"
}

@test "yaml_list_item output parses back to the original entry" {
    local item line value
    for item in /opt/a '*.env' '!x/y' 'a#b' "it's" '~' 'k: v' '[abc]*.key' '$HOME/x'; do
        line=$(yaml_list_item "$item")
        parse_yaml_scalar "${line#- }" value
        assert_equal "$value" "$item"
    done
}

# --- legacy_list_lines --------------------------------------------------------

@test "legacy_list_lines converts entries and drops comments and blank lines" {
    write_file "$LEGACY_DIR/whitelist.txt" \
        "# header comment" \
        "" \
        "/opt/tools" \
        "  ~/.local/share   # inline comment" \
        "*.env" \
        "   "
    run legacy_list_lines "$LEGACY_DIR/whitelist.txt"
    assert_success
    assert_output "- /opt/tools
- ~/.local/share
- '*.env'"
}

@test "legacy_list_lines handles CRLF and a missing final newline" {
    printf '/opt/a\r\n/opt/b' > "$LEGACY_DIR/whitelist.txt"
    run legacy_list_lines "$LEGACY_DIR/whitelist.txt"
    assert_output "- /opt/a
- /opt/b"
}

# --- legacy_env_lines ---------------------------------------------------------

@test "legacy_env_lines converts KEY=VALUE lines and copies values verbatim" {
    write_file "$LEGACY_DIR/.env" \
        "# comment" \
        "" \
        "FOO=bar" \
        "export PATH_ADD=\$HOME/bin" \
        "QUOTED=\"a # b\"" \
        "  SPACED = value  " \
        "EMPTY="
    run --separate-stderr legacy_env_lines "$LEGACY_DIR/.env"
    assert_success
    assert_output 'FOO: bar
PATH_ADD: $HOME/bin
QUOTED: "a # b"
SPACED: value
EMPTY: ""'
    assert_equal "$stderr" ""
}

@test "legacy_env_lines skips invalid lines with a warning naming the line" {
    write_file "$LEGACY_DIR/.env" "FOO=1" "not an assignment" "1BAD=x" "BAR=2"
    run --separate-stderr legacy_env_lines "$LEGACY_DIR/.env"
    assert_output "FOO: 1
BAR: 2"
    [[ "$stderr" == *"$LEGACY_DIR/.env:2: not a KEY=VALUE entry (skipped)"* ]]
    [[ "$stderr" == *"$LEGACY_DIR/.env:3: not a KEY=VALUE entry (skipped)"* ]]
}

@test "legacy_env_lines strips CRLF line endings" {
    printf 'FOO=bar\r\n' > "$LEGACY_DIR/.env"
    run legacy_env_lines "$LEGACY_DIR/.env"
    assert_output "FOO: bar"
}

# --- yaml_merge_block ---------------------------------------------------------

@test "yaml_merge_block appends a missing block to the end of the file" {
    write_file "$BATS_TEST_TMPDIR/config.yaml" "agent: opencode"
    write_file "$BATS_TEST_TMPDIR/lines" "- /opt/a" "- /opt/b"
    run --separate-stderr yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" whitelist list "$BATS_TEST_TMPDIR/lines"
    assert_success
    assert_output "agent: opencode

whitelist:
  - /opt/a
  - /opt/b"
}

@test "yaml_merge_block merges into an existing block list with its indentation" {
    write_file "$BATS_TEST_TMPDIR/config.yaml" \
        "whitelist:" \
        "    - /opt/a" \
        "    # comment" \
        "    - /opt/b" \
        "blacklist:" \
        "  - secrets/"
    write_file "$BATS_TEST_TMPDIR/lines" "- /opt/c"
    run yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" whitelist list "$BATS_TEST_TMPDIR/lines"
    assert_success
    assert_output "whitelist:
    - /opt/a
    # comment
    - /opt/b
    - /opt/c
blacklist:
  - secrets/"
}

@test "yaml_merge_block merges into an unindented block list" {
    write_file "$BATS_TEST_TMPDIR/config.yaml" "blacklist:" "- a" "agent: x"
    write_file "$BATS_TEST_TMPDIR/lines" "- b"
    run yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" blacklist list "$BATS_TEST_TMPDIR/lines"
    assert_output "blacklist:
- a
- b
agent: x"
}

@test "yaml_merge_block keeps existing list entries and reports the duplicates" {
    write_file "$BATS_TEST_TMPDIR/config.yaml" "whitelist:" "  - /opt/a  # keep me"
    write_file "$BATS_TEST_TMPDIR/lines" "- /opt/a" "- /opt/b" "- /opt/b"
    run --separate-stderr yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" whitelist list "$BATS_TEST_TMPDIR/lines"
    assert_success
    assert_output "whitelist:
  - /opt/a  # keep me
  - /opt/b"
    assert_equal "$stderr" "- /opt/a
- /opt/b"
}

@test "yaml_merge_block keeps existing env keys in map mode" {
    write_file "$BATS_TEST_TMPDIR/config.yaml" "env:" "  FOO: original" "agent: x"
    write_file "$BATS_TEST_TMPDIR/lines" "FOO: new" "BAR: 1"
    run --separate-stderr yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" env map "$BATS_TEST_TMPDIR/lines"
    assert_success
    assert_output "env:
  FOO: original
  BAR: 1
agent: x"
    assert_equal "$stderr" "FOO: new"
}

@test "yaml_merge_block converts empty inline [] and {} into a block" {
    write_file "$BATS_TEST_TMPDIR/config.yaml" "whitelist: []  # none yet" "env: {}"
    write_file "$BATS_TEST_TMPDIR/list" "- /opt/a"
    write_file "$BATS_TEST_TMPDIR/map" "FOO: 1"
    run yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" whitelist list "$BATS_TEST_TMPDIR/list"
    assert_output "whitelist:
  - /opt/a
env: {}"
    run yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" env map "$BATS_TEST_TMPDIR/map"
    assert_output "whitelist: []  # none yet
env:
  FOO: 1"
}

@test "yaml_merge_block exits 2 for a non-empty inline value" {
    write_file "$BATS_TEST_TMPDIR/config.yaml" "whitelist: [/opt/a]"
    write_file "$BATS_TEST_TMPDIR/lines" "- /opt/b"
    run yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" whitelist list "$BATS_TEST_TMPDIR/lines"
    assert_failure 2
    write_file "$BATS_TEST_TMPDIR/config.yaml" "env: {A: 1}"
    run yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" env map "$BATS_TEST_TMPDIR/lines"
    assert_failure 2
}

@test "yaml_merge_block does not match a key that is only a prefix" {
    write_file "$BATS_TEST_TMPDIR/config.yaml" "whitelist_extra: x"
    write_file "$BATS_TEST_TMPDIR/lines" "- /opt/a"
    run yaml_merge_block "$BATS_TEST_TMPDIR/config.yaml" whitelist list "$BATS_TEST_TMPDIR/lines"
    assert_success
    assert_output "whitelist_extra: x

whitelist:
  - /opt/a"
}

@test "yaml_merge_block output is parsed back with all entries" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_file "$f" "whitelist:" "  - /opt/a" "env:" "  FOO: 1"
    write_file "$BATS_TEST_TMPDIR/lines" "- '*.env'" "- /opt/b"
    yaml_merge_block "$f" whitelist list "$BATS_TEST_TMPDIR/lines" > "$BATS_TEST_TMPDIR/merged"
    parse_config_file "$BATS_TEST_TMPDIR/merged"
    assert_equal "${WHITELIST_ENTRIES[*]}" "/opt/a *.env /opt/b"
    assert_equal "${ENV_VARS[*]}" "FOO=1"
}

# --- migrate_legacy_file ------------------------------------------------------

@test "migrate_legacy_file does nothing for a missing source" {
    MIGRATED_SOURCES=()
    declare -gA MIGRATED_TARGETS=()
    write_file "$BATS_TEST_TMPDIR/staged.yaml" "agent: x"
    migrate_legacy_file "$LEGACY_DIR/missing.txt" whitelist list \
        "$BATS_TEST_TMPDIR/staged.yaml" /target.yaml "$BATS_TEST_TMPDIR"
    assert_equal "${#MIGRATED_SOURCES[@]}" 0
    assert_equal "${#MIGRATED_TARGETS[@]}" 0
}

@test "migrate_legacy_file merges into the staged file and records source and target" {
    MIGRATED_SOURCES=()
    declare -gA MIGRATED_TARGETS=()
    local staged="$BATS_TEST_TMPDIR/staged.yaml" tmp="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$tmp"
    write_file "$staged" "whitelist:" "  - /opt/a"
    write_file "$LEGACY_DIR/whitelist.txt" "/opt/a" "/opt/b"
    migrate_legacy_file "$LEGACY_DIR/whitelist.txt" whitelist list "$staged" /target.yaml "$tmp" 2> "$BATS_TEST_TMPDIR/err"
    assert_equal "$(cat "$staged")" "whitelist:
  - /opt/a
  - /opt/b"
    assert_equal "${MIGRATED_SOURCES[*]}" "$LEGACY_DIR/whitelist.txt"
    assert_equal "${MIGRATED_TARGETS[$staged]}" /target.yaml
    assert_file_contains "$BATS_TEST_TMPDIR/err" "kept the existing entry: - /opt/a"
    # The source itself is only renamed by migrate_legacy_config
    assert_file_exists "$LEGACY_DIR/whitelist.txt"
}

@test "migrate_legacy_file reports only the key of a skipped env entry" {
    MIGRATED_SOURCES=()
    declare -gA MIGRATED_TARGETS=()
    local staged="$BATS_TEST_TMPDIR/staged.yaml" tmp="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$tmp"
    write_file "$staged" "env:" "  FOO: old"
    write_file "$LEGACY_DIR/.env" "FOO=secret-new-value"
    run migrate_legacy_file "$LEGACY_DIR/.env" env map "$staged" /target.yaml "$tmp"
    assert_success
    assert_output --partial "kept the existing entry: FOO"
    refute_output --partial "secret-new-value"
}

@test "migrate_legacy_file fails and leaves the staged file alone for an inline block" {
    MIGRATED_SOURCES=()
    declare -gA MIGRATED_TARGETS=()
    local staged="$BATS_TEST_TMPDIR/staged.yaml" tmp="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$tmp"
    write_file "$staged" "blacklist: [a]"
    write_file "$LEGACY_DIR/blacklist.txt" "b"
    run migrate_legacy_file "$LEGACY_DIR/blacklist.txt" blacklist list "$staged" /target.yaml "$tmp"
    assert_failure 1
    assert_output --partial "'blacklist' in /target.yaml uses the inline form"
    assert_equal "$(cat "$staged")" "blacklist: [a]"
}

# --- migrate_legacy_config ----------------------------------------------------

@test "migrate_legacy_config creates config.yaml and config.local.yaml from all legacy files" {
    local cfg="$TEST_HOME/.config/ai-agent-sandbox/config.yaml"
    local cfg_local="$TEST_HOME/.config/ai-agent-sandbox/config.local.yaml"
    write_file "$LEGACY_DIR/whitelist.txt" "/opt/tools" "*.json"
    write_file "$LEGACY_DIR/blacklist.txt" "secrets/"
    write_file "$LEGACY_DIR/.env" "FOO=bar"
    write_file "$LEGACY_DIR/.env.local" "TOKEN=abc"
    run_migration "$cfg" "$cfg_local"
    assert_success
    assert_file_exists "$cfg"
    assert_file_exists "$cfg_local"
    assert_file_contains "$cfg" "^  - '\*.json'$"
    local f
    for f in whitelist.txt blacklist.txt .env .env.local; do
        assert_file_not_exists "$LEGACY_DIR/$f"
        assert_file_exists "$LEGACY_DIR/$f.migrated"
    done

    parse_config_file "$cfg"
    parse_config_file "$cfg_local"
    assert_equal "${WHITELIST_ENTRIES[*]}" "/opt/tools *.json"
    assert_equal "${BLACKLIST_PATHS[*]}" "secrets/"
    assert_equal "${ENV_VARS[*]}" "FOO=bar TOKEN=abc"
}

@test "migrate_legacy_config only writes the files that receive entries" {
    local cfg="$BATS_TEST_TMPDIR/cfg/config.yaml" cfg_local="$BATS_TEST_TMPDIR/cfg/config.local.yaml"
    write_file "$LEGACY_DIR/blacklist.txt" "secrets/"
    run_migration "$cfg" "$cfg_local"
    assert_success
    assert_file_exists "$cfg"
    assert_file_not_exists "$cfg_local"
    assert_file_exists "$LEGACY_DIR/blacklist.txt.migrated"
}

@test "migrate_legacy_config merges into an existing config.yaml and keeps its permissions" {
    local cfg="$BATS_TEST_TMPDIR/cfg/config.yaml" cfg_local="$BATS_TEST_TMPDIR/cfg/config.local.yaml"
    write_file "$cfg" "profile: work" "whitelist:" "  - /opt/a" "env:" "  FOO: keep"
    chmod 600 "$cfg"
    write_file "$LEGACY_DIR/whitelist.txt" "/opt/a" "/opt/b"
    write_file "$LEGACY_DIR/.env" "FOO=drop" "BAR=add"
    run_migration "$cfg" "$cfg_local"
    assert_success
    assert_output --partial "kept the existing entry: - /opt/a"
    assert_output --partial "kept the existing entry: FOO"
    run stat -c %a "$cfg"
    assert_output 600

    parse_config_file "$cfg"
    assert_equal "$PROFILE" work
    assert_equal "${WHITELIST_ENTRIES[*]}" "/opt/a /opt/b"
    assert_equal "${ENV_VARS[*]}" "FOO=keep BAR=add"
}

@test "migrate_legacy_config writes nothing when one file cannot be merged" {
    local cfg="$BATS_TEST_TMPDIR/cfg/config.yaml" cfg_local="$BATS_TEST_TMPDIR/cfg/config.local.yaml"
    write_file "$cfg" "env: {A: 1}"
    write_file "$LEGACY_DIR/whitelist.txt" "/opt/a"
    write_file "$LEGACY_DIR/.env" "FOO=bar"
    write_file "$LEGACY_DIR/.env.local" "TOKEN=abc"
    run_migration "$cfg" "$cfg_local"
    assert_failure
    assert_output --partial "Migration aborted, no files were changed"
    assert_equal "$(cat "$cfg")" "env: {A: 1}"
    assert_file_not_exists "$cfg_local"
    local f
    for f in whitelist.txt .env .env.local; do
        assert_file_exists "$LEGACY_DIR/$f"
        assert_file_not_exists "$LEGACY_DIR/$f.migrated"
    done
}

@test "migrate_legacy_config keeps an existing *.migrated backup" {
    local cfg="$BATS_TEST_TMPDIR/cfg/config.yaml" cfg_local="$BATS_TEST_TMPDIR/cfg/config.local.yaml"
    write_file "$LEGACY_DIR/blacklist.txt.migrated" "old backup"
    write_file "$LEGACY_DIR/blacklist.txt" "secrets/"
    run_migration "$cfg" "$cfg_local"
    assert_success
    assert_file_not_exists "$LEGACY_DIR/blacklist.txt"
    assert_equal "$(cat "$LEGACY_DIR/blacklist.txt.migrated")" "old backup"
    run compgen -G "$LEGACY_DIR/blacklist.txt.migrated.*"
    assert_success
}

@test "migrate_legacy_config removes its staging directory" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmpdir"
    mkdir -p "$TMPDIR"
    local cfg="$BATS_TEST_TMPDIR/cfg/config.yaml" cfg_local="$BATS_TEST_TMPDIR/cfg/config.local.yaml"
    write_file "$LEGACY_DIR/whitelist.txt" "/opt/a"
    run_migration "$cfg" "$cfg_local"
    assert_success
    run compgen -G "$TMPDIR/ai-agent-sandbox-migrate.*"
    assert_failure

    write_file "$cfg" "whitelist: [x]"
    write_file "$LEGACY_DIR/whitelist.txt" "/opt/a"
    run_migration "$cfg" "$cfg_local"
    assert_failure
    run compgen -G "$TMPDIR/ai-agent-sandbox-migrate.*"
    assert_failure
}
