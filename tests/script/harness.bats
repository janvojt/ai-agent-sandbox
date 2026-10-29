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
    run_sandbox --dry-run --whitelist-path /sys/class
    assert_args_contain BWRAP_RECORDED --ro-bind /sys/class /sys/class
}
