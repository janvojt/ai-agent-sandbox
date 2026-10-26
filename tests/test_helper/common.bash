# Shared setup for the bats tests.
#
# Every test gets its own HOME, working directory and stub directory below
# BATS_TEST_TMPDIR, so the host configuration is never read or written.
# Unit tests source the script (it returns before its main section when
# sourced) and call single functions; script tests run it as a subprocess
# with a stub bwrap that records its arguments.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX_SCRIPT="$REPO_ROOT/ai-agent-sandbox.sh"

bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-file

# Create the per-test directories and strip host settings that the script
# reads from the environment.
setup_test_env() {
    TEST_HOME="$BATS_TEST_TMPDIR/home"
    TEST_WORK="$BATS_TEST_TMPDIR/work"
    STUB_DIR="$BATS_TEST_TMPDIR/stubs"
    BWRAP_ARGS_FILE="$BATS_TEST_TMPDIR/bwrap.args"
    mkdir -p "$TEST_HOME" "$TEST_WORK" "$STUB_DIR"
    TEST_HOME="$(cd "$TEST_HOME" && pwd -P)"
    TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
    export HOME="$TEST_HOME"
    export PATH="$STUB_DIR:$PATH"
    local var
    for var in $(compgen -e); do
        case "$var" in
            AI_AGENT_SANDBOX_*|CLAUDE*|OPENCODE*|GNUPGHOME|DOCKER_HOST)
                unset "$var" ;;
        esac
    done
    cd "$TEST_WORK"
}

# Source the script from the test working directory. Its defaults are
# computed from HOME and the current directory at this point, so call it
# after setup_test_env (and after exporting any AI_AGENT_SANDBOX_* variables
# a test needs). The script enables `set -euo pipefail`; -u and pipefail are
# switched off again so bats internals and assertions behave as usual.
load_sandbox_script() {
    # shellcheck source=../../ai-agent-sandbox.sh
    source "$SANDBOX_SCRIPT"
    set +u +o pipefail
}

# Usage: stub_command <name> [script-body]
# Create an executable <name> in STUB_DIR (first on PATH). The body defaults
# to `exit 0`.
stub_command() {
    local name="$1" body="${2:-exit 0}"
    printf '#!/bin/bash\n%s\n' "$body" > "$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

# Stub bwrap that advertises overlay support and records its arguments, one
# per line, in BWRAP_ARGS_FILE instead of starting a sandbox. Exits with
# STUB_BWRAP_STATUS (default 0).
stub_bwrap() {
    stub_command bwrap "if [[ \"\${1:-}\" == --help ]]; then echo '--overlay-src'; exit 0; fi
printf '%s\n' \"\$@\" > '$BWRAP_ARGS_FILE'
exit \${STUB_BWRAP_STATUS:-0}"
}

# Usage: run_sandbox [args...]
# Run the script as a subprocess in TEST_WORK with stdin from /dev/null and a
# stub bwrap and claude. The network mode defaults to host (isolated mode needs
# pasta and real namespaces); export AI_AGENT_SANDBOX_NETWORK to change it.
# Sets bats' status/output (stdout and stderr combined, colors stripped), loads
# the recorded bwrap arguments into BWRAP_RECORDED and the command bwrap was
# asked to run (everything after the first --) into SANDBOX_COMMAND.
run_sandbox() {
    [[ -x "$STUB_DIR/bwrap" ]] || stub_bwrap
    [[ -x "$STUB_DIR/claude" ]] || stub_command claude 'echo "2.1.0 (Claude Code)"'
    rm -f "$BWRAP_ARGS_FILE"
    run env AI_AGENT_SANDBOX_NETWORK="${AI_AGENT_SANDBOX_NETWORK:-host}" \
        bash "$SANDBOX_SCRIPT" "$@" </dev/null
    output="$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')"
    mapfile -t lines <<< "$output"
    BWRAP_RECORDED=()
    SANDBOX_COMMAND=()
    if [[ -f "$BWRAP_ARGS_FILE" ]]; then
        mapfile -t BWRAP_RECORDED < "$BWRAP_ARGS_FILE"
        local i
        for ((i = 0; i < ${#BWRAP_RECORDED[@]}; i++)); do
            if [[ "${BWRAP_RECORDED[i]}" == -- ]]; then
                SANDBOX_COMMAND=("${BWRAP_RECORDED[@]:i+1}")
                break
            fi
        done
    fi
}

# Usage: args_contain_sequence <expected...> -- <actual...>
# Succeeds when the expected words appear consecutively in the actual list.
args_contain_sequence() {
    local -a expected=() actual=()
    while [[ $# -gt 0 && "$1" != -- ]]; do expected+=("$1"); shift; done
    shift
    actual=("$@")
    local i j n=${#expected[@]}
    for ((i = 0; i + n <= ${#actual[@]}; i++)); do
        for ((j = 0; j < n; j++)); do
            [[ "${actual[i + j]}" == "${expected[j]}" ]] || continue 2
        done
        return 0
    done
    return 1
}

# Usage: assert_args_contain <array-name> <expected...>
# Fail with the full argument list when the words are not consecutive in the
# named array (BWRAP_ARGS for unit tests, BWRAP_RECORDED for script tests).
assert_args_contain() {
    local -n _args="$1"
    shift
    if ! args_contain_sequence "$@" -- "${_args[@]}"; then
        batslib_print_kv_single_or_multi 8 \
            'expected' "$*" \
            'actual' "$(printf '%s\n' "${_args[@]}")" \
            | batslib_decorate "argument sequence not found" | fail
    fi
}

# Usage: refute_args_contain <array-name> <unexpected...>
refute_args_contain() {
    local -n _args="$1"
    shift
    if args_contain_sequence "$@" -- "${_args[@]}"; then
        batslib_print_kv_single_or_multi 8 \
            'unexpected' "$*" \
            'actual' "$(printf '%s\n' "${_args[@]}")" \
            | batslib_decorate "argument sequence present" | fail
    fi
}
