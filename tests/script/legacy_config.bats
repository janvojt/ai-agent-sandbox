#!/usr/bin/env bats
# Script-level tests of the deprecated whitelist.txt/blacklist.txt/.env files:
# used or ignored per level, always warned about (even with --quiet), never
# migrated without a terminal, and --migrate-project-conf.

setup() {
    load ../test_helper/common
    setup_test_env
    USER_DIR="$TEST_HOME/.config/ai-agent-sandbox"
    PROJECT_DIR="$TEST_WORK/.ai-agent-sandbox"
    mkdir -p "$USER_DIR" "$PROJECT_DIR"
}

@test "user-level legacy files without a config.yaml are used with a deprecation warning" {
    printf '/usr/bin\n/usr/share\n' > "$USER_DIR/whitelist.txt"
    printf 'secrets\n' > "$USER_DIR/blacklist.txt"
    mkdir "$TEST_WORK/secrets"
    run_sandbox --dry-run -q
    assert_success
    assert_output --partial "Warning: Using deprecated user-level configuration files:"
    assert_output --partial "will be dropped in a future release"
    assert_args_contain BWRAP_RECORDED --ro-bind /usr/share /usr/share
    assert_args_contain BWRAP_RECORDED --tmpfs "$TEST_WORK/secrets"
    # Not migrated without a terminal, and no default config generated
    assert_file_exists "$USER_DIR/whitelist.txt"
    assert_file_not_exists "$USER_DIR/config.yaml"
}

@test "user-level legacy files next to a config.yaml are ignored with a warning" {
    printf 'whitelist:\n  - /usr/bin\n' > "$USER_DIR/config.yaml"
    printf '/usr/share\n' > "$USER_DIR/whitelist.txt"
    run_sandbox --dry-run -q
    assert_success
    assert_output --partial "Warning: Ignoring deprecated user-level configuration files"
    assert_output --partial "$USER_DIR/whitelist.txt"
    refute_args_contain BWRAP_RECORDED --ro-bind /usr/share /usr/share
}

@test "a user config.local.yaml alone also makes the user-level legacy files ignored" {
    printf 'whitelist:\n  - /usr/bin\n' > "$USER_DIR/config.local.yaml"
    printf '/usr/share\n' > "$USER_DIR/whitelist.txt"
    run_sandbox --dry-run -q
    assert_success
    assert_output --partial "Ignoring deprecated user-level"
    refute_args_contain BWRAP_RECORDED --ro-bind /usr/share /usr/share
}

@test "project-level legacy files are decided independently of the user level" {
    printf 'whitelist:\n  - /usr/bin\n' > "$USER_DIR/config.yaml"
    printf '/usr/share\n' > "$PROJECT_DIR/whitelist.txt"
    run_sandbox --dry-run -q
    assert_success
    assert_output --partial "Using deprecated project-level configuration files"
    assert_output --partial "--migrate-project-conf"
    assert_args_contain BWRAP_RECORDED --ro-bind /usr/share /usr/share
}

@test "project-level legacy files next to a project config.yaml are ignored" {
    printf 'whitelist:\n  - /usr/bin\n' > "$USER_DIR/config.yaml"
    printf 'quiet: false\n' > "$PROJECT_DIR/config.yaml"
    printf '/usr/share\n' > "$PROJECT_DIR/whitelist.txt"
    run_sandbox --dry-run -q
    assert_success
    assert_output --partial "Ignoring deprecated project-level"
    refute_args_contain BWRAP_RECORDED --ro-bind /usr/share /usr/share
}

@test "--migrate-project-conf merges into the existing config.yaml and exits" {
    printf 'whitelist:\n  - /usr/bin\n' > "$USER_DIR/config.yaml"
    printf 'whitelist:\n  - /opt/a\nblacklist: []\n' > "$PROJECT_DIR/config.yaml"
    printf '/opt/a\n/opt/b\n' > "$PROJECT_DIR/whitelist.txt"
    printf 'secrets\n' > "$PROJECT_DIR/blacklist.txt"
    printf 'FOO=bar\n' > "$PROJECT_DIR/.env"
    run_sandbox --migrate-project-conf
    assert_success
    assert_output --partial "Project configuration migrated."
    assert_equal "${#BWRAP_RECORDED[@]}" 0
    assert_file_exists "$PROJECT_DIR/whitelist.txt.migrated"
    assert_file_exists "$PROJECT_DIR/blacklist.txt.migrated"
    assert_file_exists "$PROJECT_DIR/.env.migrated"
    assert_file_not_exists "$PROJECT_DIR/whitelist.txt"
    run grep -c -- '- /opt/a' "$PROJECT_DIR/config.yaml"
    assert_output 1
    run grep -- '- /opt/b' "$PROJECT_DIR/config.yaml"
    assert_success
    run grep -- '- secrets' "$PROJECT_DIR/config.yaml"
    assert_success
    run grep 'FOO' "$PROJECT_DIR/config.yaml"
    assert_success
}

@test "--migrate-project-conf aborts without changes on an inline whitelist" {
    printf 'whitelist:\n  - /usr/bin\n' > "$USER_DIR/config.yaml"
    printf 'whitelist: [/opt/a]\n' > "$PROJECT_DIR/config.yaml"
    printf '/opt/b\n' > "$PROJECT_DIR/whitelist.txt"
    cp "$PROJECT_DIR/config.yaml" "$BATS_TEST_TMPDIR/before.yaml"
    run_sandbox --migrate-project-conf
    assert_failure 1
    assert_file_exists "$PROJECT_DIR/whitelist.txt"
    assert_file_not_exists "$PROJECT_DIR/whitelist.txt.migrated"
    run cmp "$BATS_TEST_TMPDIR/before.yaml" "$PROJECT_DIR/config.yaml"
    assert_success
}

@test "--migrate-project-conf without legacy files has nothing to do" {
    run_sandbox --migrate-project-conf
    assert_success
    assert_output --partial "nothing to migrate"
}
