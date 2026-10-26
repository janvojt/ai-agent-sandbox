#!/usr/bin/env bats
# Script-level tests of the network mode selection: sources and their
# precedence, the fallback without the isolation tools, and invalid values.
# Isolated mode itself needs real namespaces (see tests/integration).

setup() {
    load ../test_helper/common
    setup_test_env
    PROJECT_DIR="$TEST_WORK/.ai-agent-sandbox"
}

# Make network isolation unavailable: an unshare without --map-user
hide_isolation_tools() {
    stub_command unshare 'echo "Usage: unshare [options]"'
}

@test "host mode shares the network and the host resolver configuration" {
    run_sandbox --dry-run --network host
    assert_success
    assert_output --partial "Network: host (full access, from --network)"
    assert_args_contain BWRAP_RECORDED --share-net --ro-bind /etc/resolv.conf /etc/resolv.conf
}

@test "none mode adds no network" {
    run_sandbox --dry-run --network none
    assert_success
    refute_args_contain BWRAP_RECORDED --share-net
    refute_args_contain BWRAP_RECORDED --ro-bind /etc/resolv.conf /etc/resolv.conf
}

@test "a network mode from a project config file is honoured and named in the summary" {
    mkdir -p "$PROJECT_DIR"
    printf 'network: none\n' > "$PROJECT_DIR/config.yaml"
    unset AI_AGENT_SANDBOX_NETWORK
    stub_bwrap
    stub_command claude
    rm -f "$BWRAP_ARGS_FILE"
    run bash "$SANDBOX_SCRIPT" --dry-run </dev/null
    assert_success
    assert_output --partial "from $PROJECT_DIR/config.yaml"
    run cat "$BWRAP_ARGS_FILE"
    refute_line --share-net
}

@test "the default falls back to the host network without the isolation tools" {
    hide_isolation_tools
    unset AI_AGENT_SANDBOX_NETWORK
    stub_bwrap
    stub_command claude
    run bash "$SANDBOX_SCRIPT" --dry-run </dev/null
    assert_success
    assert_output --partial "falling back to the host network"
    run cat "$BWRAP_ARGS_FILE"
    assert_line --share-net
}

@test "an explicit isolated mode without the isolation tools is fatal" {
    hide_isolation_tools
    run_sandbox --dry-run --network isolated
    assert_failure 1
    assert_output --partial "network isolation (from --network) needs unshare with --map-user"
    assert_equal "${#BWRAP_RECORDED[@]}" 0
}

@test "invalid network settings are fatal" {
    run_sandbox --dry-run --network full
    assert_failure 1
    run_sandbox --dry-run --host-port 70000
    assert_failure 1
    run_sandbox --dry-run --host-port abc
    assert_failure 1
    printf 'whitelist:\n  - /usr/bin\nnetwork: full\n' > "$BATS_TEST_TMPDIR/config.yaml"
    AI_AGENT_SANDBOX_CONFIG="$BATS_TEST_TMPDIR/config.yaml" run_sandbox --dry-run
    assert_failure 1
}
