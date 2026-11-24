#!/usr/bin/env bats
# Checks of the script-level harness: the stub bwrap records the arguments.

setup() {
    load ../test_helper/common
    setup_test_env
}

@test "a dry run reaches the stub bwrap with the working directory bound" {
    run_sandbox --dry-run
    assert_success
    assert_args_contain BWRAP_RECORDED --bind "$TEST_WORK" "$TEST_WORK"
    assert_args_contain BWRAP_RECORDED -- /bin/bash
}

@test "the exit status of the sandbox is passed through" {
    export STUB_BWRAP_STATUS=42
    run_sandbox --dry-run -q
    assert_equal "$status" 42
}

@test "bwrap starts with SIGINT and SIGQUIT at their default disposition" {
    # A background job of a non-interactive bash ignores both, and everything
    # inside would inherit that (Ctrl+C could not stop a build). The script is
    # started with both at the default: bash cannot reset a signal that was
    # already ignored when it started (as under bats --jobs)
    env --default-signal=INT true 2>/dev/null || skip "env --default-signal needs coreutils 8.31"
    RUN_SANDBOX_ENV_OPTIONS=(--default-signal=INT,QUIT)
    run_sandbox --dry-run -q
    assert_success
    local mask
    mask=$(awk '{print $2}' "$BWRAP_SIGIGN_FILE")
    assert_equal "$(( 0x$mask & 0x6 ))" 0
}

@test "without a terminal the sandbox runs in a new session" {
    run_sandbox --dry-run
    assert_success
    assert_args_contain BWRAP_RECORDED --new-session
    assert_output --partial "Terminal Session: new (no terminal attached)"
}

@test "--no-new-session keeps the terminal session" {
    run_sandbox --dry-run --no-new-session
    assert_success
    refute_args_contain BWRAP_RECORDED --new-session
    assert_output --partial "Terminal Session: shared (--no-new-session)"
}

@test "the host's /sys is not mounted, a whitelisted /sys path is" {
    run_sandbox --dry-run
    assert_success
    refute_args_contain BWRAP_RECORDED --ro-bind /sys /sys
    assert_args_contain BWRAP_RECORDED --tmpfs /sys
    # /sys/devices exists both on a host and inside the minimal /sys
    run_sandbox --dry-run --whitelist-path /sys/devices
    assert_args_contain BWRAP_RECORDED --ro-bind /sys/devices /sys/devices
}

@test "only allowed host variables reach bwrap and only the passed ones are named" {
    export GITHUB_TOKEN=secret-value ANTHROPIC_API_KEY=key DISPLAY=:0 LC_ALL=C
    run_sandbox --dry-run
    assert_success
    run cat "$BWRAP_ENV_FILE"
    refute_line --partial GITHUB_TOKEN
    refute_line --partial DISPLAY
    assert_line ANTHROPIC_API_KEY=key
    assert_line LC_ALL=C
    run_sandbox --dry-run
    assert_output --regexp "Hidden Host Environment Variables: [1-9][0-9]*"
    refute_output --partial GITHUB_TOKEN
    assert_output --regexp "Passed Host Environment Variables \([0-9]+\): .*ANTHROPIC_API_KEY"
    refute_output --partial "=key"
    refute_output --partial secret-value
    # values must not end up on the bwrap command line either
    refute_args_contain BWRAP_RECORDED key
}

@test "env: entries and --env still set variables" {
    export GITHUB_TOKEN=from-host
    run_sandbox --dry-run --env 'GH=$GITHUB_TOKEN'
    assert_success
    assert_recorded_env GH from-host
}

@test "env: and --env values reach bwrap's environment, not its arguments" {
    mkdir -p "$TEST_WORK/.ai-agent-sandbox"
    printf 'env:\n  CI_PASSWORD: project-secret\n' > "$TEST_WORK/.ai-agent-sandbox/config.local.yaml"
    run_sandbox --dry-run --env 'CLI_TOKEN=cli-secret'
    assert_success
    assert_recorded_env CI_PASSWORD project-secret
    assert_recorded_env CLI_TOKEN cli-secret
    refute_args_mention BWRAP_RECORDED project-secret
    refute_args_mention BWRAP_RECORDED cli-secret
    refute_args_contain BWRAP_RECORDED --setenv
    # the script's own values travel the same way
    assert_recorded_env HOME "$TEST_HOME"
    assert_recorded_env PWD "$TEST_WORK"
    [[ "${BWRAP_ENV_RECORDED[PATH]}" == "$TEST_HOME/.local/bin:"* ]] || fail "PATH is ${BWRAP_ENV_RECORDED[PATH]}"
}

@test "sandbox removals keep their order with env: entries" {
    export CLAUDE_CONFIG_DIR=/host/claude SSH_AUTH_SOCK=/host/ssh
    run_sandbox --dry-run --env 'SSH_AUTH_SOCK=/sandbox/ssh'
    assert_success
    refute_recorded_env CLAUDE_CONFIG_DIR
    # env entries come after the script's own removals and win, as before
    assert_recorded_env SSH_AUTH_SOCK /sandbox/ssh
}

@test "an env: entry named like a script variable does not break the bwrap command" {
    run_sandbox --dry-run --env 'BWRAP_ARGS=x' --env 'BWRAP_BIN=y' --env 'IFS=:'
    assert_success
    assert_recorded_env BWRAP_ARGS x
    assert_recorded_env BWRAP_BIN y
    assert_args_contain BWRAP_RECORDED --tmpfs /tmp
}
