#!/usr/bin/env bats
# Script-level tests of the config files: auto-generation of the user-level
# config.yaml, precedence of the files, environment and flags, removed options,
# and the read-only project configuration directory.

setup() {
    load ../test_helper/common
    setup_test_env
    USER_CONFIG="$TEST_HOME/.config/ai-agent-sandbox/config.yaml"
    USER_CONFIG_LOCAL="$TEST_HOME/.config/ai-agent-sandbox/config.local.yaml"
    PROJECT_DIR="$TEST_WORK/.ai-agent-sandbox"
}

# Usage: write_config <file> <content>
write_config() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
}

# Usage: write_user_config <content>
# A user config.yaml prevents the generated default, so it needs a whitelist
# of its own for the sandbox to start.
write_user_config() {
    write_config "$USER_CONFIG" $'whitelist:\n  - /usr/bin\n'"$1"
}

@test "a fresh HOME gets a generated config.yaml with whitelist and blacklist used in the same run" {
    run_sandbox --dry-run
    assert_success
    assert_file_exists "$USER_CONFIG"
    run grep -c '^whitelist:\|^blacklist:' "$USER_CONFIG"
    assert_output 2
    assert_args_contain BWRAP_RECORDED --ro-bind /usr/bin /usr/bin
}

@test "an explicit whitelist path generates only the blacklist section" {
    run_sandbox --dry-run --whitelist-path /usr/bin
    assert_success
    run grep '^whitelist:' "$USER_CONFIG"
    assert_failure
    run grep '^blacklist:' "$USER_CONFIG"
    assert_success
}

@test "an explicit blacklist path generates only the whitelist section" {
    run_sandbox --dry-run --blacklist-path secrets
    assert_success
    run grep '^blacklist:' "$USER_CONFIG"
    assert_failure
    run grep '^whitelist:' "$USER_CONFIG"
    assert_success
}

@test "explicit whitelist and blacklist paths generate no config file" {
    run_sandbox --dry-run --whitelist-path /usr/bin --blacklist-path secrets
    assert_success
    assert_file_not_exists "$USER_CONFIG"
}

@test "a project whitelist on a fresh HOME still generates the user config" {
    write_config "$PROJECT_DIR/config.yaml" $'whitelist:\n  - /usr/share'
    run_sandbox --dry-run
    assert_success
    assert_file_exists "$USER_CONFIG"
    assert_args_contain BWRAP_RECORDED --ro-bind /usr/share /usr/share
}

@test "an existing user config.local.yaml prevents the generation" {
    write_config "$USER_CONFIG_LOCAL" 'quiet: false'
    run_sandbox --dry-run
    assert_failure 1
    assert_output --partial "No whitelist entries found"
    assert_file_not_exists "$USER_CONFIG"
}

@test "the removed options --whitelist, --blacklist and --env-path are fatal" {
    local option
    for option in --whitelist --blacklist --env-path; do
        run_sandbox --dry-run "$option" /tmp/x
        assert_failure 1
        assert_output --partial "$option"
        assert_equal "${#BWRAP_RECORDED[@]}" 0
    done
}

@test "the removed *_files config keys are fatal" {
    local key
    for key in whitelist_files blacklist_files env_files; do
        write_config "$USER_CONFIG" "$key: [/tmp/x]"
        run_sandbox --dry-run
        assert_failure 1
        assert_output --partial "$key"
        assert_equal "${#BWRAP_RECORDED[@]}" 0
    done
}

@test "an invalid boolean in a config file is fatal" {
    write_config "$USER_CONFIG" 'docker: ture'
    run_sandbox --dry-run
    assert_failure 1
    assert_output --partial ture
}

@test "profile precedence: user < user local < project < project local" {
    write_user_config 'profile: from-user'
    run_sandbox --dry-run
    assert_output --partial "Profile: from-user (from $USER_CONFIG)"

    write_config "$USER_CONFIG_LOCAL" 'profile: from-user-local'
    run_sandbox --dry-run
    assert_output --partial "Profile: from-user-local (from $USER_CONFIG_LOCAL)"

    write_config "$PROJECT_DIR/config.yaml" 'profile: from-project'
    run_sandbox --dry-run
    assert_output --partial "Profile: from-project (from $PROJECT_DIR/config.yaml)"

    write_config "$PROJECT_DIR/config.local.yaml" 'profile: from-project-local'
    run_sandbox --dry-run
    assert_output --partial "Profile: from-project-local (from $PROJECT_DIR/config.local.yaml)"
}

@test "the profile flag beats the config files" {
    write_user_config 'profile: from-user'
    run_sandbox --dry-run --profile flagged
    assert_success
    assert_output --partial "Profile: flagged"
}

@test "--verbose beats quiet: true and --quiet silences the summary" {
    write_user_config 'quiet: true'
    run_sandbox --dry-run
    refute_output --partial "Sandbox Configuration"
    run_sandbox --dry-run --verbose
    assert_output --partial "Sandbox Configuration"
}

@test "--no-docker beats docker: true" {
    write_user_config 'docker: true'
    run_sandbox --dry-run --no-docker
    assert_success
    refute_output --partial "Docker Socket Proxy"
}

@test "whitelist, blacklist, env and agent_args from the config reach the sandbox" {
    mkdir -p "$TEST_WORK/secrets" "$TEST_WORK/data"
    write_config "$PROJECT_DIR/config.yaml" $'whitelist:\n  - /usr/share\n  - data/:rw\nblacklist:\n  - secrets\nenv:\n  FOO: bar\nagent_args: [--model, x]'
    run_sandbox
    assert_success
    assert_args_contain BWRAP_RECORDED --ro-bind /usr/share /usr/share
    assert_args_contain BWRAP_RECORDED --bind "$TEST_WORK/data/" "$TEST_WORK/data/"
    assert_args_contain BWRAP_RECORDED --tmpfs "$TEST_WORK/secrets"
    assert_args_contain BWRAP_RECORDED --setenv FOO bar
    assert_equal "${SANDBOX_COMMAND[*]}" "$STUB_DIR/claude --dangerously-skip-permissions --model x"
}

@test "agent_args from the config come before the command-line agent arguments" {
    write_user_config 'agent_args: [--model, x]'
    run_sandbox -- --print hi
    assert_success
    assert_equal "${SANDBOX_COMMAND[*]}" "$STUB_DIR/claude --dangerously-skip-permissions --model x --print hi"
}

@test "the project configuration directory is mounted read-only after the working directory" {
    write_config "$PROJECT_DIR/config.yaml" 'quiet: false'
    run_sandbox --dry-run
    assert_success
    assert_args_contain BWRAP_RECORDED --bind "$TEST_WORK" "$TEST_WORK" --ro-bind "$PROJECT_DIR" "$PROJECT_DIR"
}

@test "blacklisted files in the project configuration directory stay hidden" {
    write_config "$PROJECT_DIR/config.yaml" $'blacklist:\n  - .ai-agent-sandbox/.env'
    touch "$PROJECT_DIR/.env"
    run_sandbox --dry-run
    assert_success
    assert_args_contain BWRAP_RECORDED --ro-bind "$PROJECT_DIR" "$PROJECT_DIR"
    assert_args_contain BWRAP_RECORDED --ro-bind /dev/null "$PROJECT_DIR/.env"
}

@test "--no-protect-project-config leaves the project configuration writable" {
    write_config "$PROJECT_DIR/config.yaml" 'quiet: false'
    run_sandbox --dry-run --no-protect-project-config
    assert_success
    refute_args_contain BWRAP_RECORDED --ro-bind "$PROJECT_DIR" "$PROJECT_DIR"
}

@test "protect_project_config: false in a project file is ignored" {
    write_config "$PROJECT_DIR/config.yaml" 'protect_project_config: false'
    run_sandbox --dry-run
    assert_success
    assert_args_contain BWRAP_RECORDED --ro-bind "$PROJECT_DIR" "$PROJECT_DIR"
}

@test "protect_project_config: false in the user config is honoured" {
    write_user_config 'protect_project_config: false'
    write_config "$PROJECT_DIR/config.yaml" 'quiet: false'
    run_sandbox --dry-run
    assert_success
    refute_args_contain BWRAP_RECORDED --ro-bind "$PROJECT_DIR" "$PROJECT_DIR"
}
