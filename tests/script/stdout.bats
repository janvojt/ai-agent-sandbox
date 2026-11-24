#!/usr/bin/env bats
# Stdout belongs to the sandboxed command alone: orchestrators (T3 Code) parse
# it as one JSON document, so the script's own setup and cleanup must not add
# a byte to it. The stub bwrap stands in for the command and writes a payload.

setup() {
    load ../test_helper/common
    setup_test_env
    PAYLOAD="$BATS_TEST_TMPDIR/payload"
    STDOUT_FILE="$BATS_TEST_TMPDIR/stdout"
    STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
    # No trailing newline and a NUL byte: the comparison is byte for byte
    printf '{"type":"result","result":"hi"}\n\0tail' > "$PAYLOAD"
    stub_command claude 'echo "2.1.0 (Claude Code)"'
    stub_payload_bwrap 'exit 0'
}

# Usage: stub_payload_bwrap <final-command>
# A bwrap that writes the payload to stdout and then runs <final-command>
stub_payload_bwrap() {
    stub_command bwrap "if [[ \"\${1:-}\" == --help ]]; then echo '--overlay-src'; exit 0; fi
cat '$PAYLOAD'
$1"
}

# A docker client that is as talkative on stdout as the real one (container
# ids and names, pull progress) and whose proxy "container" creates the
# upstream socket in the directory mounted at /proxy. Calls are logged.
stub_docker() {
    command -v python3 >/dev/null 2>&1 || skip "the Docker API filter needs python3"
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || skip "the Docker API filter needs python3 3.8"
    DOCKER_CALLS="$BATS_TEST_TMPDIR/docker.calls"
    # shellcheck disable=SC2016  # expanded by the stub
    stub_command docker 'echo "$*" >> "'"$DOCKER_CALLS"'"
case "${1:-}" in
    run)
        for arg in "$@"; do
            [[ "$arg" == *:/proxy ]] && dir="${arg%:/proxy}"
        done
        python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$dir/docker.sock" || exit 1
        echo 4f5a8b0c9d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a
        ;;
    stop|rm) echo "${@: -1}" ;;
    info) echo "[\"name=seccomp,profile=builtin\"]" ;;
    version) echo "Docker version 29.0.0" ;;
    pull) echo "Status: Downloaded newer image" ;;
    logs) echo "proxy log line" ;;
    ps) ;;
esac
exit 0'
}

# Usage: run_split [args...]
# Run the script with stdout and stderr in separate files; sets `status`
run_split() {
    status=0
    env AI_AGENT_SANDBOX_NETWORK=host bash "$SANDBOX_SCRIPT" "$@" \
        </dev/null >"$STDOUT_FILE" 2>"$STDERR_FILE" || status=$?
}

assert_stdout_is_payload() {
    if ! cmp -s "$PAYLOAD" "$STDOUT_FILE"; then
        batslib_print_kv_single_or_multi 8 \
            'expected' "$(cat -v "$PAYLOAD")" \
            'actual' "$(cat -v "$STDOUT_FILE")" \
            'stderr' "$(cat -v "$STDERR_FILE")" \
            | batslib_decorate "stdout differs from the command's output" | fail
    fi
}

@test "stdout carries only the command's output" {
    run_split
    assert_equal "$status" 0
    assert_stdout_is_payload
    # the summary is still printed, on stderr
    run cat "$STDERR_FILE"
    assert_output --partial "AI Coding Agent Sandbox Configuration"
}

@test "stdout carries only the command's output on a fresh home with --quiet" {
    run_split --quiet
    assert_equal "$status" 0
    assert_stdout_is_payload
    assert_file_exist "$TEST_HOME/.config/ai-agent-sandbox/config.yaml"
}

@test "stdout carries only the command's output when the command fails" {
    stub_payload_bwrap 'exit 3'
    run_split --quiet
    assert_equal "$status" 3
    assert_stdout_is_payload
}

@test "stdout carries only the command's output with Docker enabled" {
    stub_docker
    run_split --quiet -d
    assert_equal "$status" 0
    assert_stdout_is_payload
    # the proxy was started and removed again (docker stop prints the name)
    run cat "$DOCKER_CALLS"
    assert_line --regexp '^run -d --name ai-agent-sandbox-proxy-[0-9]+ '
    assert_line --regexp '^stop ai-agent-sandbox-proxy-[0-9]+$'
    assert_line --regexp '^rm -f ai-agent-sandbox-proxy-[0-9]+$'
}

@test "stdout carries only the command's output with Docker enabled and the summary printed" {
    stub_docker
    stub_payload_bwrap 'exit 3'
    run_split -d
    assert_equal "$status" 3
    assert_stdout_is_payload
    run cat "$STDERR_FILE"
    assert_output --partial "Cleaning up socket proxy"
}

@test "stdout carries only the command's output when the script is terminated" {
    stub_docker
    stub_payload_bwrap 'exec sleep 30'
    env AI_AGENT_SANDBOX_NETWORK=host bash "$SANDBOX_SCRIPT" --quiet -d \
        </dev/null >"$STDOUT_FILE" 2>"$STDERR_FILE" &
    local pid=$! i
    for ((i = 0; i < 200; i++)); do
        cmp -s "$PAYLOAD" "$STDOUT_FILE" && break
        sleep 0.1
    done
    kill -TERM "$pid"
    status=0
    wait "$pid" || status=$?
    assert_equal "$status" 143
    assert_stdout_is_payload
    run cat "$DOCKER_CALLS"
    assert_line --regexp '^stop ai-agent-sandbox-proxy-[0-9]+$'
}
