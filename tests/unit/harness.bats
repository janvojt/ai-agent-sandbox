#!/usr/bin/env bats
# Checks of the test harness itself: sourcing must not run the main section.

setup() {
    load ../test_helper/common
    setup_test_env
}

@test "sourcing the script defines functions without running the main section" {
    load_sandbox_script
    run type -t parse_yaml_scalar
    assert_output function
    # The main section would have resolved a profile and set the EXIT trap
    assert_equal "$PROFILE" ""
    run trap -p EXIT
    refute_output --partial cleanup_sandbox
}

@test "defaults follow the test HOME and working directory" {
    load_sandbox_script
    assert_equal "$WORKING_DIR" "$TEST_WORK"
    assert_equal "$DEFAULT_CONFIG_FILE" "$TEST_HOME/.config/ai-agent-sandbox/config.yaml"
    assert_equal "$PROFILES_DIR" "$TEST_HOME/.local/share/ai-agent-sandbox/profiles"
}

@test "args_contain_sequence matches consecutive words only" {
    run args_contain_sequence --ro-bind /a /a -- --tmpfs /tmp --ro-bind /a /a
    assert_success
    run args_contain_sequence --ro-bind /a /b -- --ro-bind /a /x /b
    assert_failure
}
