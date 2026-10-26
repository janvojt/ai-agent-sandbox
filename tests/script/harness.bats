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
