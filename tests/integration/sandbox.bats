#!/usr/bin/env bats
# bats file_tags=integration
#
# Integration tests that start real bwrap sandboxes (dry-run mode, the
# commands come from stdin). They need unprivileged user namespaces and are
# only run by `tests/run.sh --integration`. The network tests use a stub pasta
# that exits 0: the user namespaces, routes and the capability drop are real,
# the connectivity through pasta (needs /dev/net/tun) is not tested here.

setup() {
    load ../test_helper/common
    setup_test_env
    command -v bwrap >/dev/null || skip "bwrap is not installed"
    stub_command claude
}

# Usage: run_real_sandbox <commands> [script args...]
# Run the script in dry-run mode with a real bwrap and feed <commands> to the
# shell inside. The network mode defaults to none.
run_real_sandbox() {
    local commands="$1"
    shift
    run bash -c 'printf "%s\n" "$1" | AI_AGENT_SANDBOX_NETWORK="${AI_AGENT_SANDBOX_NETWORK:-none}" bash "$0" --dry-run -q "${@:2}"' \
        "$SANDBOX_SCRIPT" "$commands" "$@"
}

@test "the exit status and stdin reach through the sandbox" {
    # read takes the line after the one it is on, the script comes from stdin too
    run_real_sandbox $'read -r line; echo "GOT:$line"; exit 42\nfrom-stdin'
    assert_equal "$status" 42
    assert_output --partial "GOT:from-stdin"
}

@test "blacklisted files and directories are not readable" {
    printf 'secret\n' > .env
    mkdir secrets
    printf 'secret\n' > secrets/key
    printf 'public\n' > README
    run_real_sandbox 'cat .env; ls secrets; cat README' --blacklist-path secrets --blacklist-path .env
    refute_output --partial secret
    refute_output --partial key
    assert_output --partial public
}

@test "the working directory is writable and the project configuration is not" {
    mkdir .ai-agent-sandbox
    printf 'quiet: true\n' > .ai-agent-sandbox/config.yaml
    run_real_sandbox 'touch created && echo work-ok; touch .ai-agent-sandbox/x || echo config-ro'
    assert_output --partial work-ok
    assert_output --partial config-ro
    assert_file_exists created
    assert_file_not_exists .ai-agent-sandbox/x
}

@test "a read-write whitelisted parent leaves every project configuration read-only" {
    local ws="$BATS_TEST_TMPDIR/ws"
    mkdir -p "$ws/proj/.ai-agent-sandbox" "$ws/other/.ai-agent-sandbox" "$ws/repo/.git"
    cd "$ws/proj"
    # a whitelist flag would leave the generated user config without a whitelist
    printf 'whitelist:\n  - "%s:rw"\n  - "%s:rw"\n' "$ws" "$ws/repo" > .ai-agent-sandbox/config.yaml
    run_real_sandbox "touch .ai-agent-sandbox/x || echo own-ro
touch $ws/other/.ai-agent-sandbox/x || echo other-ro
touch $ws/repo/.ai-agent-sandbox/x || echo repo-ro
touch $ws/other/file && echo other-rw"
    assert_output --partial own-ro
    assert_output --partial other-ro
    assert_output --partial repo-ro
    assert_output --partial other-rw
    assert_file_not_exists .ai-agent-sandbox/x
    assert_file_not_exists "$ws/other/.ai-agent-sandbox/x"
}

@test "the agent cannot create a project configuration in the working directory" {
    run_real_sandbox 'touch .ai-agent-sandbox/config.yaml || echo create-refused'
    assert_output --partial create-refused
    assert_file_not_exists .ai-agent-sandbox/config.yaml
}

@test "--no-protect-project-config makes the project configuration writable" {
    mkdir .ai-agent-sandbox
    run_real_sandbox 'touch .ai-agent-sandbox/x && echo config-rw' --no-protect-project-config
    assert_output --partial config-rw
}

@test "the host home directory is not visible" {
    mkdir -p "$TEST_HOME/.ssh"
    printf 'key\n' > "$TEST_HOME/.ssh/id_ed25519"
    run_real_sandbox 'ls -A ~/.ssh 2>&1 || echo no-ssh'
    assert_output --partial no-ssh
}

@test "OpenCode's ACP agent started in the home directory sees none of it" {
    mkdir -p "$TEST_HOME/project"
    printf 'secret\n' > "$TEST_HOME/project/notes"
    cd "$TEST_HOME"
    run_real_sandbox 'echo "PWD:$PWD"; ls -A ~/project 2>&1 || echo no-project' --agent opencode -- acp
    assert_success
    assert_output --partial "PWD:$TEST_HOME"
    assert_output --partial no-project
    refute_output --partial notes
}

@test "a git worktree outside the working directory can commit" {
    command -v git >/dev/null || skip "git is not installed"
    local repo="$BATS_TEST_TMPDIR/repo"
    git init -q "$repo"
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    git -C "$repo" worktree add -q "$BATS_TEST_TMPDIR/wt" -b feature
    cd "$BATS_TEST_TMPDIR/wt"
    run_real_sandbox 'git status --short && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m inside && echo committed'
    assert_output --partial committed
    run git -C "$repo" log --format=%s feature
    assert_line inside
}

@test "a forged .git link does not expose the target directory" {
    mkdir -p "$BATS_TEST_TMPDIR/private"
    printf 'secret\n' > "$BATS_TEST_TMPDIR/private/data"
    printf 'gitdir: %s\n' "$BATS_TEST_TMPDIR/private" > .git
    run_real_sandbox "cat '$BATS_TEST_TMPDIR/private/data' 2>&1 || echo hidden"
    assert_output --partial hidden
    refute_output --partial secret
}

@test "SIGTERM and SIGHUP end the sandbox with 143 and 129" {
    # A unique sleep, matched at the start of the command line so the test
    # shell (whose source contains the marker) does not count
    local marker='sleep 31.4159' signal expected pid script_pid status_code i
    for signal in TERM HUP; do
        expected=143
        [[ "$signal" == HUP ]] && expected=129
        (echo "$marker" | AI_AGENT_SANDBOX_NETWORK=none bash "$SANDBOX_SCRIPT" --dry-run -q >/dev/null 2>&1) &
        pid=$!
        for ((i = 0; i < 100; i++)); do
            pgrep -f "^$marker" >/dev/null && break
            sleep 0.1
        done
        run pgrep -f "^$marker"
        assert_success
        script_pid=$(pgrep -P "$pid" -f "$SANDBOX_SCRIPT" | head -n 1)
        assert [ -n "$script_pid" ]
        SECONDS=0
        kill -s "$signal" "$script_pid"
        status_code=0
        wait "$pid" || status_code=$?
        assert_equal "$status_code" "$expected"
        assert [ "$SECONDS" -lt 5 ]
        run pgrep -f "^$marker"
        assert_failure
    done
}

@test "isolated mode blocks private ranges with routes the sandbox cannot change" {
    stub_command pasta
    AI_AGENT_SANDBOX_NETWORK=isolated run_real_sandbox \
        'ip route; ip route add 10.9.0.0/16 dev lo || echo add-denied; grep CapEff /proc/self/status; cat /proc/sys/net/ipv4/ping_group_range'
    assert_success
    local blocked
    for blocked in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
        assert_output --partial "unreachable $blocked metric 100"
    done
    assert_output --partial add-denied
    assert_output --regexp $'CapEff:\t0+\n'
    assert_output --partial "$(id -g)	$(id -g)"
}

@test "isolated mode writes the sandbox resolver into resolv.conf" {
    stub_command pasta
    AI_AGENT_SANDBOX_NETWORK=isolated run_real_sandbox 'cat /etc/resolv.conf'
    assert_success
    assert_output --partial "nameserver 169.254.2.3"
}

@test "no network namespace leftovers remain after an isolated run" {
    stub_command pasta
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    AI_AGENT_SANDBOX_NETWORK=isolated run_real_sandbox 'true'
    assert_success
    run find "$TMPDIR" -name 'ai-agent-sandbox-net.*'
    assert_output ""
}
