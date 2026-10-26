#!/usr/bin/env bats
# Project profile check: a project may pin a profile and refuse to run under a
# different one from AI_AGENT_SANDBOX_PROFILE (or, with --strict-profile, under
# the implicit default), but it can never pick the credentials itself. Only
# profiles from project files are recorded in PROJECT_PROFILE.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
}

# Usage: given_profiles <project-profile> <profile> <profile-source>
given_profiles() {
    PROJECT_PROFILE="$1"
    PROJECT_PROFILE_SOURCE="$PROJECT_CONFIG_DIR/config.local.yaml"
    PROFILE="$2"
    PROFILE_SOURCE="$3"
}

# --- check_project_profile ----------------------------------------------------------

@test "the environment variable naming the pinned profile runs" {
    given_profiles work work AI_AGENT_SANDBOX_PROFILE
    run check_project_profile
    assert_success
    assert_output ""
}

@test "the environment variable naming another profile is a profile mismatch" {
    given_profiles work private AI_AGENT_SANDBOX_PROFILE
    run check_project_profile
    assert_failure 1
    assert_output --partial "profile mismatch"
    assert_output --partial "$PROJECT_CONFIG_DIR/config.local.yaml requires profile 'work'"
    assert_output --partial "AI_AGENT_SANDBOX_PROFILE is 'private'"
    assert_output --partial "--profile private"
}

@test "the environment variable naming default is refused for a pinned profile" {
    given_profiles work default AI_AGENT_SANDBOX_PROFILE
    run check_project_profile
    assert_failure 1
    assert_output --partial "profile mismatch"
}

@test "an explicit --profile is not checked" {
    given_profiles work private --profile
    run check_project_profile
    assert_success
}

@test "an explicit --profile is not checked with --strict-profile either" {
    given_profiles work default --profile
    STRICT_PROFILE=true
    run check_project_profile
    assert_success
}

@test "--strict-profile without the variable counts as default and refuses a pinned profile" {
    # Main section: no profile from env/flag means the project's value applies
    given_profiles work work "$PROJECT_CONFIG_DIR/config.local.yaml"
    STRICT_PROFILE=true
    run check_project_profile
    assert_failure 1
    assert_output --partial "profile mismatch"
    assert_output --partial "counts as 'default' with --strict-profile"
}

@test "--strict-profile without the variable runs for a project pinned to default" {
    given_profiles default default "$PROJECT_CONFIG_DIR/config.yaml"
    STRICT_PROFILE=true
    run check_project_profile
    assert_success
}

@test "a project pinned to default refuses AI_AGENT_SANDBOX_PROFILE=work" {
    given_profiles default work AI_AGENT_SANDBOX_PROFILE
    run check_project_profile
    assert_failure 1
    assert_output --partial "profile mismatch"
}

@test "without --strict-profile a missing variable is not checked" {
    given_profiles work work "$PROJECT_CONFIG_DIR/config.local.yaml"
    run check_project_profile
    assert_success
}

@test "without a project profile nothing is checked" {
    given_profiles "" private AI_AGENT_SANDBOX_PROFILE
    run check_project_profile
    assert_success
    STRICT_PROFILE=true
    PROFILE=default
    PROFILE_SOURCE=default
    run check_project_profile
    assert_success
}

# --- Recording the project profile -----------------------------------------------

@test "is_project_config_file accepts files below the project config directory only" {
    run is_project_config_file "$PROJECT_CONFIG_DIR/config.yaml"
    assert_success
    run is_project_config_file "$DEFAULT_CONFIG_FILE"
    assert_failure
    run is_project_config_file "$TEST_WORK/.ai-agent-sandbox-evil/config.yaml"
    assert_failure
}

@test "is_project_config_file accepts the main checkout's config.local.yaml when set" {
    run is_project_config_file /repo/.ai-agent-sandbox/config.local.yaml
    assert_failure
    MAIN_CHECKOUT_CONFIG_LOCAL_FILE=/repo/.ai-agent-sandbox/config.local.yaml
    run is_project_config_file /repo/.ai-agent-sandbox/config.local.yaml
    assert_success
}

@test "an empty main checkout file does not make every empty path a project file" {
    run is_project_config_file ""
    assert_failure
}

@test "a profile from a project file is recorded as the project profile" {
    apply_config_scalar profile work "$PROJECT_CONFIG_DIR/config.yaml" false
    assert_equal "$PROFILE" work
    assert_equal "$PROFILE_SOURCE" "$PROJECT_CONFIG_DIR/config.yaml"
    assert_equal "$PROJECT_PROFILE" work
    assert_equal "$PROJECT_PROFILE_SOURCE" "$PROJECT_CONFIG_DIR/config.yaml"
}

@test "a profile from a user-level file is not recorded as the project profile" {
    apply_config_scalar profile work "$DEFAULT_CONFIG_FILE" false
    assert_equal "$PROFILE" work
    assert_equal "$PROJECT_PROFILE" ""
    assert_equal "$PROJECT_PROFILE_SOURCE" ""
}

@test "a null project profile clears the recorded project profile" {
    apply_config_scalar profile work "$PROJECT_CONFIG_DIR/config.yaml" false
    apply_config_scalar profile "" "$PROJECT_CONFIG_DIR/config.local.yaml" true
    assert_equal "$PROFILE" ""
    assert_equal "$PROJECT_PROFILE" ""
}

@test "a user-level profile does not override the recorded project profile" {
    apply_config_scalar profile work "$PROJECT_CONFIG_DIR/config.yaml" false
    apply_config_scalar profile private "$DEFAULT_CONFIG_LOCAL_FILE" false
    assert_equal "$PROFILE" private
    assert_equal "$PROJECT_PROFILE" work
}

@test "a profile in the main checkout's config.local.yaml counts as a project profile" {
    MAIN_CHECKOUT_CONFIG_LOCAL_FILE=/repo/.ai-agent-sandbox/config.local.yaml
    apply_config_scalar profile work /repo/.ai-agent-sandbox/config.local.yaml false
    assert_equal "$PROJECT_PROFILE" work
}

@test "config files: a user-level profile with the variable set to another profile is not checked" {
    mkdir -p "$(dirname "$DEFAULT_CONFIG_FILE")"
    echo "profile: work" > "$DEFAULT_CONFIG_FILE"
    load_config_files
    assert_equal "$PROJECT_PROFILE" ""
    PROFILE=private
    PROFILE_SOURCE=AI_AGENT_SANDBOX_PROFILE
    run check_project_profile
    assert_success
}

@test "config files: a project config.yaml profile with the variable set to another profile is refused" {
    mkdir -p "$PROJECT_CONFIG_DIR"
    echo "profile: work" > "$PROJECT_CONFIG_FILE"
    load_config_files
    assert_equal "$PROJECT_PROFILE" work
    PROFILE=private
    PROFILE_SOURCE=AI_AGENT_SANDBOX_PROFILE
    run check_project_profile
    assert_failure 1
    assert_output --partial "$PROJECT_CONFIG_FILE requires profile 'work'"
}
