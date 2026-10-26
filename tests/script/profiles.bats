#!/usr/bin/env bats
# Script-level tests of profiles: creation of the store, mounts, listing,
# invalid names and the project profile check.

setup() {
    load ../test_helper/common
    setup_test_env
    PROFILES="$TEST_HOME/.local/share/ai-agent-sandbox/profiles"
    PROJECT_DIR="$TEST_WORK/.ai-agent-sandbox"
}

@test "a new profile is created with an empty configuration and a private store" {
    run_sandbox --dry-run --profile test
    assert_success
    assert_output --partial "Created new profile 'test'"
    assert_dir_exists "$PROFILES/test/home/.claude"
    run cat "$PROFILES/test/home/.claude.json"
    assert_output '{}'
    run stat -c %a "$PROFILES"
    assert_output 700
    assert_args_contain BWRAP_RECORDED --bind "$PROFILES/test/home/.claude" "$TEST_HOME/.claude"
    assert_args_contain BWRAP_RECORDED --bind "$PROFILES/test/home/.claude.json" "$TEST_HOME/.claude.json"
    assert_args_contain BWRAP_RECORDED --unsetenv CLAUDE_CONFIG_DIR
}

@test "the default profile binds the host configuration" {
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Profile: default (host configuration, from default)"
    assert_args_contain BWRAP_RECORDED --bind "$TEST_HOME/.claude" "$TEST_HOME/.claude"
    assert_dir_not_exists "$PROFILES/default"
}

@test "the profile store is hidden when a whitelist entry exposes it" {
    mkdir -p "$PROFILES/other/home"
    run_sandbox --dry-run --profile test --whitelist-path "$TEST_HOME/.local/share" --whitelist-path /usr/bin
    assert_success
    assert_args_contain BWRAP_RECORDED --ro-bind "$TEST_HOME/.local/share" "$TEST_HOME/.local/share"
    assert_args_contain BWRAP_RECORDED --tmpfs "$PROFILES"
}

@test "--list-profiles lists default and the created profiles and marks logins" {
    mkdir -p "$PROFILES/work/home/.claude" "$PROFILES/private/home"
    touch "$PROFILES/work/home/.claude/.credentials.json"
    run_sandbox --list-profiles
    assert_success
    assert_line "default (host configuration)"
    assert_line "work (claude: logged in)"
    assert_line "private"
    assert_equal "${#BWRAP_RECORDED[@]}" 0
}

@test "invalid profile names are fatal" {
    local name
    for name in 'bad/name' '../x' '.hidden'; do
        run_sandbox --dry-run --profile "$name"
        assert_failure 1
        assert_equal "${#BWRAP_RECORDED[@]}" 0
    done
    assert_dir_not_exists "$TEST_HOME/.local/share/ai-agent-sandbox/x"
}

@test "AI_AGENT_SANDBOX_PROFILE beats the project config and --profile beats both" {
    mkdir -p "$PROJECT_DIR"
    printf 'profile: work\n' > "$PROJECT_DIR/config.local.yaml"
    AI_AGENT_SANDBOX_PROFILE=work run_sandbox --dry-run
    assert_success
    assert_output --partial "Profile: work (from AI_AGENT_SANDBOX_PROFILE)"
    AI_AGENT_SANDBOX_PROFILE=private run_sandbox --dry-run --profile private
    assert_success
    assert_output --partial "Profile: private (from --profile)"
}

@test "a project-pinned profile refuses a different AI_AGENT_SANDBOX_PROFILE" {
    mkdir -p "$PROJECT_DIR"
    printf 'profile: work\n' > "$PROJECT_DIR/config.yaml"
    AI_AGENT_SANDBOX_PROFILE=private run_sandbox --dry-run
    assert_failure 1
    assert_output --partial "profile mismatch"
    assert_equal "${#BWRAP_RECORDED[@]}" 0
    assert_dir_not_exists "$PROFILES/private"
}

@test "--strict-profile treats a missing AI_AGENT_SANDBOX_PROFILE as default" {
    mkdir -p "$PROJECT_DIR"
    printf 'profile: work\n' > "$PROJECT_DIR/config.yaml"
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Profile: work"
    run_sandbox --dry-run --strict-profile
    assert_failure 1
    assert_output --partial "profile mismatch"
    run_sandbox --dry-run --strict-profile --profile default
    assert_success
}

@test "--strict-profile changes nothing without a pinned profile" {
    run_sandbox --dry-run --strict-profile
    assert_success
    assert_output --partial "Profile: default"
}

@test "a profile in a user-level file is not checked against the environment" {
    mkdir -p "$TEST_HOME/.config/ai-agent-sandbox"
    printf 'whitelist:\n  - /usr/bin\nprofile: work\n' > "$TEST_HOME/.config/ai-agent-sandbox/config.yaml"
    AI_AGENT_SANDBOX_PROFILE=private run_sandbox --dry-run
    assert_success
    assert_output --partial "Profile: private"
}
