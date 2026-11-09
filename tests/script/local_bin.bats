#!/usr/bin/env bats
# Script-level tests of the ~/.local/bin overlay of a native Claude install:
# writes inside are lost at exit, an in-sandbox Claude update is kept.

setup() {
    load ../test_helper/common
    setup_test_env
    VERSIONS="$TEST_HOME/.local/share/claude/versions"
    STATE="$TEST_HOME/.local/share/ai-agent-sandbox"
    mkdir -p "$VERSIONS" "$TEST_HOME/.local/bin"
    install_claude_version 2.1.0
    ln -s "$VERSIONS/2.1.0" "$TEST_HOME/.local/bin/claude"
}

install_claude_version() {
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$VERSIONS/$1"
    chmod +x "$VERSIONS/$1"
}

# Stub bwrap that acts like an agent updating Claude and installing a tool: it
# writes into the upper layer of the ~/.local/bin overlay it was given.
stub_bwrap_writing_upper_layer() {
    stub_command bwrap "if [[ \"\${1:-}\" == --help ]]; then echo '--overlay-src'; exit 0; fi
printf '%s\n' \"\$@\" > '$BWRAP_ARGS_FILE'
while [[ \$# -gt 0 ]]; do
    if [[ \"\$1\" == --overlay ]]; then
        ln -sfn '$VERSIONS/2.2.0' \"\$2/claude\"
        printf 'x' > \"\$2/tool\"
        break
    fi
    shift
done
exit 0"
}

@test "an in-sandbox Claude update is kept, other writes to ~/.local/bin are not" {
    install_claude_version 2.2.0
    stub_bwrap_writing_upper_layer
    run_sandbox --dry-run
    assert_success
    assert_output --partial "writes are lost at exit"

    local i upper=""
    for ((i = 0; i < ${#BWRAP_RECORDED[@]}; i++)); do
        [[ "${BWRAP_RECORDED[i]}" == --overlay ]] && upper="${BWRAP_RECORDED[i+1]}"
    done
    assert_equal "${upper%/run.*}" "$STATE/local-bin-runs"
    assert_not_exists "${upper%/upper}"
    assert_equal "$(ls -A "$STATE/local-bin-runs")" ""
    assert_equal "$(readlink "$STATE/claude-bin/claude")" "$VERSIONS/2.2.0"
    assert_equal "$(ls -A "$STATE/claude-bin")" claude
}

@test "each run gets its own upper layer seeded with the kept launcher" {
    install_claude_version 2.2.0
    mkdir -p "$STATE/claude-bin"
    ln -s "$VERSIONS/2.2.0" "$STATE/claude-bin/claude"
    stub_command bwrap "if [[ \"\${1:-}\" == --help ]]; then echo '--overlay-src'; exit 0; fi
printf '%s\n' \"\$@\" > '$BWRAP_ARGS_FILE'
while [[ \$# -gt 0 && \"\$1\" != --overlay ]]; do shift; done
ls -A \"\$2\" > '$BATS_TEST_TMPDIR/upper.list'"
    run_sandbox --dry-run
    assert_success
    assert_equal "$(cat "$BATS_TEST_TMPDIR/upper.list")" claude
    refute_args_contain BWRAP_RECORDED --overlay "$STATE/claude-bin"
}

@test "a whitelisted ~/.local/share does not expose the overlay state" {
    mkdir -p "$STATE/claude-bin"
    run_sandbox --dry-run --whitelist-path-rw '~/.local/share'
    assert_success
    assert_args_contain BWRAP_RECORDED --tmpfs "$STATE/local-bin-runs"
    assert_args_contain BWRAP_RECORDED --tmpfs "$STATE/claude-bin"
}
