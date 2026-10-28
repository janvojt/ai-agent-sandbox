#!/usr/bin/env bats
# Script-level tests of the agent command line: permission flags for Claude
# Code, OpenCode 1 and 2 launch arguments, the version fast path and the
# refusal to run in the home directory.

setup() {
    load ../test_helper/common
    setup_test_env
    OPENCODE_BIN="$TEST_HOME/.opencode/bin/opencode"
}

# Usage: stub_opencode <script-body>
# OpenCode is looked up at ~/.opencode/bin/opencode, not on PATH.
stub_opencode() {
    mkdir -p "$(dirname "$OPENCODE_BIN")"
    printf '#!/bin/bash\n%s\n' "$1" > "$OPENCODE_BIN"
    chmod +x "$OPENCODE_BIN"
}

@test "Claude Code gets --dangerously-skip-permissions by default" {
    run_sandbox -- --model x
    assert_success
    assert_output --partial "Agent Command: claude --dangerously-skip-permissions --model x"
    assert_equal "${SANDBOX_COMMAND[*]}" "$STUB_DIR/claude --dangerously-skip-permissions --model x"
}

@test "a permission mode chosen by the caller is not overridden" {
    local -a variant
    local case
    for case in '--permission-mode default' '--permission-mode=plan' \
        '--dangerously-skip-permissions' '--allow-dangerously-skip-permissions'; do
        read -r -a variant <<< "$case"
        run_sandbox -- "${variant[@]}" --print hi
        assert_success
        assert_equal "${SANDBOX_COMMAND[*]}" "$STUB_DIR/claude $case --print hi"
    done
}

@test "a dry run starts bash instead of the agent" {
    run_sandbox --dry-run -- --model x
    assert_success
    assert_equal "${SANDBOX_COMMAND[*]}" /bin/bash
    refute_output --partial "Agent Command:"
}

@test "OpenCode 2 runs standalone with automatic permissions" {
    stub_opencode 'echo 2.0.1'
    run_sandbox --agent opencode -- run hi
    assert_success
    assert_output --partial "Agent: opencode (major version 2)"
    assert_equal "${SANDBOX_COMMAND[*]}" "$OPENCODE_BIN run --standalone --auto hi"
}

@test "OpenCode 1 gets the build agent and permissions through the environment" {
    stub_opencode 'echo 1.4.2'
    run_sandbox --agent opencode -- run hi
    assert_success
    assert_equal "${SANDBOX_COMMAND[*]}" "$OPENCODE_BIN --agent build run hi"
    assert_args_contain BWRAP_RECORDED --setenv OPENCODE_PERMISSION '{"*":"allow"}'
}

@test "a bare --version is answered by the host binary without a sandbox" {
    stub_command claude 'echo "claude version probe $*"'
    stub_opencode 'echo "opencode version probe $*"'
    cd "$TEST_HOME"
    local flag
    for flag in --version -v; do
        run_sandbox -- "$flag"
        assert_success
        assert_output "claude version probe $flag"
        assert_equal "${#BWRAP_RECORDED[@]}" 0
        run_sandbox --agent opencode -- "$flag"
        assert_success
        assert_output "opencode version probe $flag"
    done
}

@test "--version with other arguments or in a dry run starts the sandbox" {
    run_sandbox -- --model x --version
    assert_success
    assert_equal "${SANDBOX_COMMAND[*]}" "$STUB_DIR/claude --dangerously-skip-permissions --model x --version"
    run_sandbox --dry-run -- --version
    assert_success
    assert_equal "${SANDBOX_COMMAND[*]}" /bin/bash
}

@test "the home directory as working directory is refused" {
    cd "$TEST_HOME"
    run_sandbox --dry-run
    assert_failure 1
    assert_output --partial "is your home directory"
    assert_equal "${#BWRAP_RECORDED[@]}" 0
}

@test "a parent of the home directory as working directory is refused" {
    cd "$TEST_HOME/.."
    run_sandbox --dry-run
    assert_failure 1
    assert_output --partial "contains your home directory"
}

@test "OpenCode in the home directory gets the T3 Code hint" {
    stub_opencode 'echo 2.0.1'
    cd "$TEST_HOME"
    run_sandbox --agent opencode -- serve
    assert_failure 1
    assert_output --partial "use OpenCode through T3's ACP"
}

@test "OpenCode's ACP agent in the home directory runs without a working directory mount" {
    stub_opencode 'echo 2.0.1'
    mkdir -p "$TEST_HOME/data"
    cd "$TEST_HOME"
    run_sandbox --agent opencode --whitelist-path data -d -- acp
    assert_success
    assert_output --partial "(not mounted: ACP agent without a project)"
    assert_output --partial "Skipped relative whitelist entry without a project directory: data"
    assert_output --partial "Docker disabled"
    assert_equal "${SANDBOX_COMMAND[*]}" "$OPENCODE_BIN acp"
    refute_args_contain BWRAP_RECORDED --bind "$TEST_HOME" "$TEST_HOME"
    refute_args_contain BWRAP_RECORDED --ro-bind "$TEST_HOME/data" "$TEST_HOME/data"
    assert_args_contain BWRAP_RECORDED --chdir "$TEST_HOME"
    assert_not_exist "$TEST_HOME/.ai-agent-sandbox"
}

@test "OpenCode's ACP agent in a project directory mounts it as usual" {
    stub_opencode 'echo 2.0.1'
    run_sandbox --agent opencode -- acp
    assert_success
    assert_equal "${SANDBOX_COMMAND[*]}" "$OPENCODE_BIN acp"
    assert_args_contain BWRAP_RECORDED --bind "$TEST_WORK" "$TEST_WORK"
    refute_output --partial "not mounted"
}

@test "the ACP exception covers neither parents of the home directory nor Claude" {
    stub_opencode 'echo 2.0.1'
    cd "$TEST_HOME/.."
    run_sandbox --agent opencode -- acp
    assert_failure 1
    assert_output --partial "contains your home directory"
    cd "$TEST_HOME"
    run_sandbox -- acp
    assert_failure 1
    assert_output --partial "is your home directory"
    run_sandbox --agent opencode -- run acp
    assert_failure 1
}

@test "--allow-home-workdir starts the sandbox in the home directory" {
    cd "$TEST_HOME"
    run_sandbox --dry-run --allow-home-workdir
    assert_success
    assert_args_contain BWRAP_RECORDED --bind "$TEST_HOME" "$TEST_HOME"
}

@test "an unknown agent is fatal" {
    run_sandbox --agent vim
    assert_failure 1
    assert_output --partial "Invalid agent 'vim'"
}
