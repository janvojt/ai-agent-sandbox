#!/usr/bin/env bats
# Script-level tests of the syscall filter: the level and its sources, the
# --seccomp argument handed to bwrap and the rule that a project may only
# tighten the filter. What the kernel does with it is in tests/integration.

setup() {
    load ../test_helper/common
    setup_test_env
    case "$(uname -m)" in
        x86_64|aarch64) ;;
        *) skip "no syscall filter for $(uname -m)" ;;
    esac
    PROJECT_DIR="$TEST_WORK/.ai-agent-sandbox"
    SECCOMP_COPY="$BATS_TEST_TMPDIR/seccomp.bpf"
}

# Stub bwrap that also copies the program it gets on --seccomp <fd>
stub_bwrap_reading_seccomp() {
    stub_command bwrap "if [[ \"\${1:-}\" == --help ]]; then echo '--overlay-src'; exit 0; fi
printf '%s\n' \"\$@\" > '$BWRAP_ARGS_FILE'
prev=''
for arg in \"\$@\"; do
    [[ \"\$prev\" == --seccomp ]] && cat <&\"\$arg\" > '$SECCOMP_COPY'
    prev=\"\$arg\"
done
exit 0"
}

@test "the default filter is passed to bwrap and named in the summary" {
    stub_bwrap_reading_seccomp
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Syscall Filter: default (from default;"
    assert_args_contain BWRAP_RECORDED --seccomp
    assert_file_exists "$SECCOMP_COPY"
    # starts with "ld [arch]"
    run od -An -N8 -tx1 "$SECCOMP_COPY"
    assert_output " 20 00 00 00 04 00 00 00"
    run ls -A "$TMPDIR"
    assert_output ""
}

@test "--seccomp off passes no filter" {
    run_sandbox --dry-run --seccomp off
    assert_success
    assert_output --partial "Syscall Filter: off (from --seccomp)"
    refute_args_contain BWRAP_RECORDED --seccomp
}

@test "AI_AGENT_SANDBOX_SECCOMP sets the level and the flag beats it" {
    AI_AGENT_SANDBOX_SECCOMP=strict run_sandbox --dry-run
    assert_success
    assert_output --partial "Syscall Filter: strict (no user namespaces or mounts, from AI_AGENT_SANDBOX_SECCOMP;"
    AI_AGENT_SANDBOX_SECCOMP=strict run_sandbox --dry-run --seccomp off
    assert_output --partial "Syscall Filter: off (from --seccomp)"
}

@test "a project file can tighten the filter" {
    mkdir -p "$PROJECT_DIR"
    printf 'seccomp: strict\n' > "$PROJECT_DIR/config.yaml"
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Syscall Filter: strict (no user namespaces or mounts, from $PROJECT_DIR/config.yaml"
}

@test "a project file cannot switch the filter off" {
    mkdir -p "$PROJECT_DIR"
    printf 'seccomp: off\n' > "$PROJECT_DIR/config.yaml"
    run_sandbox --dry-run
    assert_success
    assert_output --partial "project files may only tighten the syscall filter"
    assert_output --partial "Syscall Filter: default (from default;"
    assert_args_contain BWRAP_RECORDED --seccomp
}

@test "a user-level file can switch the filter off" {
    mkdir -p "$(dirname "$TEST_HOME/.config/ai-agent-sandbox/config.yaml")"
    printf 'seccomp: off\nwhitelist:\n  - /usr\n' > "$TEST_HOME/.config/ai-agent-sandbox/config.yaml"
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Syscall Filter: off (from $TEST_HOME/.config/ai-agent-sandbox/config.yaml)"
    refute_args_contain BWRAP_RECORDED --seccomp
}

@test "invalid levels are fatal" {
    run_sandbox --dry-run --seccomp on
    assert_failure
    assert_output --partial "invalid --seccomp level 'on'"
    AI_AGENT_SANDBOX_SECCOMP=yes run_sandbox --dry-run
    assert_failure
    assert_output --partial "invalid AI_AGENT_SANDBOX_SECCOMP 'yes'"
}
