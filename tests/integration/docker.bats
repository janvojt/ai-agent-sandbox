#!/usr/bin/env bats
# bats file_tags=integration
#
# The Docker API filter against a real daemon ($DOCKER_HOST or
# /var/run/docker.sock), and --enable-docker end to end (also needs bwrap
# with user namespaces). Skipped without a reachable daemon. Pulls alpine.

setup_file() {
    DOCKER_SKIP=""
    if ! command -v docker >/dev/null || ! command -v python3 >/dev/null; then
        DOCKER_SKIP="docker or python3 is not installed"
    elif ! timeout 20 docker info >/dev/null 2>&1; then
        DOCKER_SKIP="no Docker daemon reachable"
    elif ! timeout 120 docker pull -q alpine >/dev/null 2>&1; then
        DOCKER_SKIP="cannot pull alpine"
    fi
    export DOCKER_SKIP
}

setup() {
    [[ -z "$DOCKER_SKIP" ]] || skip "$DOCKER_SKIP"
    load ../test_helper/common
    local host="${DOCKER_HOST:-unix:///var/run/docker.sock}"
    UPSTREAM_SOCKET="${host#unix://}"
    setup_test_env
    load_sandbox_script
    OWNER="$BATS_TEST_TMPDIR/owner"
    FILTER_SOCKET="$BATS_TEST_TMPDIR/filter.sock"
    docker_filter_program > "$BATS_TEST_TMPDIR/docker_filter.py"
    python3 -I "$BATS_TEST_TMPDIR/docker_filter.py" "$FILTER_SOCKET" "$UPSTREAM_SOCKET" "$OWNER" \
        2>"$BATS_TEST_TMPDIR/filter.log" &
    FILTER_PID=$!
    local i
    for ((i = 0; i < 50; i++)); do
        [[ -S "$FILTER_SOCKET" ]] && break
        sleep 0.1
    done
    FOREIGN=""
}

teardown() {
    [[ -z "${FILTER_PID:-}" ]] || kill "$FILTER_PID" 2>/dev/null || true
    [[ -z "${FOREIGN:-}" ]] || DOCKER_HOST="unix://$UPSTREAM_SOCKET" docker rm -f "$FOREIGN" >/dev/null 2>&1 || true
    if [[ -n "${OWNER:-}" && -n "${UPSTREAM_SOCKET:-}" ]]; then
        DOCKER_HOST="unix://$UPSTREAM_SOCKET" docker ps -aq --filter "label=ai-agent-sandbox.owner=$OWNER" \
            | xargs -r env DOCKER_HOST="unix://$UPSTREAM_SOCKET" docker rm -f >/dev/null 2>&1 || true
        DOCKER_HOST="unix://$UPSTREAM_SOCKET" docker volume ls -q --filter "label=ai-agent-sandbox.owner=$OWNER" \
            | xargs -r env DOCKER_HOST="unix://$UPSTREAM_SOCKET" docker volume rm >/dev/null 2>&1 || true
    fi
}

filtered_docker() {
    DOCKER_HOST="unix://$FILTER_SOCKET" timeout 120 docker "$@"
}

@test "ordinary containers work through the filter: run, stdin, exec, logs" {
    run filtered_docker run --rm alpine echo hello
    assert_success
    assert_output hello
    run bash -c 'echo piped | DOCKER_HOST="unix://$1" docker run --rm -i alpine cat' _ "$FILTER_SOCKET"
    assert_output piped
    local id
    id="$(filtered_docker run -d alpine sh -c 'echo started; sleep 30')"
    run filtered_docker exec "$id" echo exec-ok
    assert_output exec-ok
    run filtered_docker logs "$id"
    assert_output started
    run filtered_docker inspect "$id" --format '{{index .Config.Labels "ai-agent-sandbox.owner"}}'
    assert_output "$OWNER"
}

@test "privileged containers, host namespaces, capabilities and devices are refused" {
    local args
    for args in "--privileged" "--pid=host" "--network=host" "--cap-add=SYS_ADMIN" \
        "--device=/dev/null:/dev/x" "--security-opt=seccomp=unconfined" "--userns=host"; do
        run filtered_docker run --rm $args alpine true
        assert_failure
        assert_output --partial "ai-agent-sandbox:"
    done
    run filtered_docker run --rm alpine mknod /tmp/x c 1 3
    assert_failure
}

@test "containers created outside the sandbox cannot be listed, inspected or entered" {
    FOREIGN="$(DOCKER_HOST="unix://$UPSTREAM_SOCKET" docker run -d alpine sleep 60)"
    run filtered_docker ps -aq
    refute_output --partial "${FOREIGN:0:12}"
    local cmd
    for cmd in "inspect $FOREIGN" "exec $FOREIGN true" "stop $FOREIGN" "rm -f $FOREIGN"; do
        run filtered_docker $cmd
        assert_failure
        assert_output --partial "was not created in this sandbox's project"
    done
    # docker cp asks with HEAD first, whose 403 carries no message
    run filtered_docker cp "$BATS_TEST_TMPDIR/docker_filter.py" "$FOREIGN:/tmp/"
    assert_failure
    run env DOCKER_HOST="unix://$UPSTREAM_SOCKET" docker exec "$FOREIGN" ls /tmp
    refute_output --partial docker_filter.py
    run filtered_docker run --rm --network "container:$FOREIGN" alpine true
    assert_failure
}

@test "volumes mounting host devices are refused, named volumes are owned" {
    run filtered_docker volume create --opt type=ext4 --opt device=/dev/sda1 evil
    assert_failure
    assert_output --partial "volume driver options"
    run filtered_docker run --rm -v "sandbox-test-$$:/x" alpine true
    assert_success
    run filtered_docker volume inspect "sandbox-test-$$" --format '{{index .Labels "ai-agent-sandbox.owner"}}'
    assert_output "$OWNER"
}

@test "--enable-docker: the sandbox reaches Docker only through the filter" {
    command -v bwrap >/dev/null && bwrap --ro-bind / / --unshare-all true 2>/dev/null \
        || skip "bwrap cannot create namespaces here"
    [[ -z "${DOCKER_HOST:-}" || "$DOCKER_HOST" == unix:///var/run/docker.sock ]] \
        || skip "--enable-docker needs the host's /var/run/docker.sock"
    stub_command claude
    run bash -c 'printf "%s\n" "docker run --rm alpine echo inside-ok; docker run --rm --privileged alpine true || echo privileged-refused; ls -la .docker-proxy" \
        | AI_AGENT_SANDBOX_NETWORK=host bash "$0" --dry-run -q --enable-docker' "$SANDBOX_SCRIPT"
    assert_output --partial inside-ok
    assert_output --partial privileged-refused
    assert_output --partial "srw-------"
    assert_not_exist "$TEST_WORK/.docker-proxy"
}
