#!/usr/bin/env bats
# The Docker API filter (docker_filter_program): the policy against a fake
# daemon state, and the HTTP relay (framing, keep-alive, hijacked streams,
# request smuggling) against a fake upstream server. Needs python3 only;
# tests/integration/docker.bats runs it against a real daemon.

setup() {
    load ../test_helper/common
    setup_test_env
    command -v python3 >/dev/null || skip "python3 is not installed"
    load_sandbox_script
    docker_filter_program > "$BATS_TEST_TMPDIR/docker_filter.py"
    cat > "$BATS_TEST_TMPDIR/harness.py" <<'EOF'
import asyncio, json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import docker_filter as f

f.OWNER = "/work"
MINE = {f.OWNER_LABEL: "/work"}
OBJECTS = {
    "/containers/mine/json": {"Config": {"Labels": MINE}},
    "/containers/theirs/json": {"Config": {"Labels": {"other": "x"}}},
    "/containers/proxy/json": {"Config": {"Labels": None}},
    "/exec/e1/json": {"ContainerID": "mine"},
    "/exec/e2/json": {"ContainerID": "theirs"},
    "/volumes/myvol": {"Labels": MINE},
    "/volumes/pgdata": {"Labels": None},
    "/networks/mynet": {"Name": "mynet", "Labels": MINE},
    "/networks/theirnet": {"Name": "theirnet", "Labels": {}},
    "/networks/bridge": {"Name": "bridge", "Labels": {}},
}
CALLS = []

async def fake_api(method, path, body=None):
    CALLS.append((method, path, body))
    key = path[len("/v1.41"):]
    if method == "POST":
        return 201, {}
    return (200, OBJECTS[key]) if key in OBJECTS else (404, None)

f.api = fake_api

async def check(method, target, body=None):
    raw = json.dumps(body).encode() if body is not None else b""
    head = "%s %s HTTP/1.1\r\nHost: d\r\nContent-Length: %d\r\n\r\n" % (method, target, len(raw))
    reader = asyncio.StreamReader()
    reader.feed_data(raw)
    reader.feed_eof()
    try:
        req = f.Request(f.Message(head.encode()))
        await f.check_request(req, reader)
    except f.Deny as e:
        return "deny: %s" % e
    out = {"target": req.target()}
    if req.body is not None:
        out["body"] = req.body
    return "allow " + json.dumps(out, sort_keys=True)

method, target = sys.argv[1], sys.argv[2]
body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
print(asyncio.run(check(method, target, body)))
for call in CALLS:
    if call[0] == "POST":
        print("upstream", json.dumps(call))
EOF
}

# Usage: filter_check <method> <target> [json-body]
filter_check() {
    run python3 -I "$BATS_TEST_TMPDIR/harness.py" "$@"
    assert_success
}

create() {
    filter_check POST /v1.41/containers/create "$1"
}

# --- Container creation -----------------------------------------------------------

@test "a plain container is allowed, labelled with the owner and loses MKNOD" {
    create '{"Image":"alpine","HostConfig":{"CapDrop":["NET_RAW"]}}'
    assert_output --partial '"ai-agent-sandbox.owner": "/work"'
    assert_output --partial '"CapDrop": ["NET_RAW", "MKNOD"]'
}

@test "privileged containers, host namespaces and devices are refused" {
    local body
    for body in '{"HostConfig":{"Privileged":true}}' \
        '{"HostConfig":{"PidMode":"host"}}' '{"HostConfig":{"NetworkMode":"host"}}' \
        '{"HostConfig":{"IpcMode":"host"}}' '{"HostConfig":{"UsernsMode":"host"}}' \
        '{"HostConfig":{"UTSMode":"host"}}' '{"HostConfig":{"CgroupnsMode":"host"}}' \
        '{"HostConfig":{"Devices":[{"PathOnHost":"/dev/sda"}]}}' \
        '{"HostConfig":{"DeviceCgroupRules":["b *:* rwm"]}}' \
        '{"HostConfig":{"DeviceRequests":[{"Count":-1}]}}' \
        '{"HostConfig":{"CgroupParent":"/"}}' '{"HostConfig":{"Runtime":"crun-unsafe"}}' \
        '{"HostConfig":{"MaskedPaths":[]}}' '{"HostConfig":{"VolumeDriver":"rexray"}}'; do
        create "$body"
        assert_output --partial "deny:"
    done
}

@test "only capabilities that act inside the container may be added" {
    create '{"HostConfig":{"CapAdd":["NET_ADMIN","CAP_SYS_PTRACE","ipc_lock"]}}'
    assert_output --partial "allow"
    local cap
    for cap in SYS_ADMIN CAP_SYS_MODULE DAC_READ_SEARCH ALL BPF SYS_RAWIO MKNOD; do
        create "{\"HostConfig\":{\"CapAdd\":[\"$cap\"]}}"
        assert_output --partial "deny: capability $cap is not allowed"
    done
}

@test "unconfined security profiles are refused, no-new-privileges is fine" {
    local opt
    for opt in seccomp=unconfined seccomp:unconfined 'seccomp={"defaultAction":"SCMP_ACT_ALLOW"}' \
        apparmor=unconfined label=disable label:disable systempaths=unconfined; do
        create "{\"HostConfig\":{\"SecurityOpt\":[$(printf '%s' "$opt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]}}"
        assert_output --partial "deny: security option"
    done
    create '{"HostConfig":{"SecurityOpt":["no-new-privileges"]}}'
    assert_output --partial "allow"
}

@test "Go's case-insensitive field names cannot smuggle settings past the filter" {
    create '{"hostconfig":{"Privileged":true}}'
    assert_output --partial "deny: field hostconfig in the request must be spelled HostConfig"
    create '{"HostConfig":{"privileged":true}}'
    assert_output --partial "deny: field privileged in HostConfig"
    create '{"HostConfig":{"PIDMODE":"host"}}'
    assert_output --partial "deny: field PIDMODE"
    create '{"HostConfig":{"Privileged":false,"PRIVILEGED":true}}'
    assert_output --partial "deny:"
    # Kelvin sign: Go folds it to k
    create '{"HostConfig":{"CaKAdd":["SYS_ADMIN"]}}'
    assert_output --partial "allow"
    create '{"HostConfig":{"Mounts":[{"type":"volume","Source":"pgdata"}]}}'
    assert_output --partial "deny: field type in Mounts"
}

@test "containers may only join their own namespaces, volumes and networks" {
    create '{"HostConfig":{"NetworkMode":"container:mine","PidMode":"container:mine"}}'
    assert_output --partial "allow"
    create '{"HostConfig":{"NetworkMode":"container:theirs"}}'
    assert_output --partial "deny: container theirs was not created"
    create '{"HostConfig":{"VolumesFrom":["proxy:ro"]}}'
    assert_output --partial "deny: container proxy was not created"
    create '{"HostConfig":{"NetworkMode":"theirnet"}}'
    assert_output --partial "deny: network theirnet"
    create '{"HostConfig":{"NetworkMode":"mynet"}}'
    assert_output --partial "allow"
    create '{"NetworkingConfig":{"EndpointsConfig":{"theirnet":{}}}}'
    assert_output --partial "deny: network theirnet"
    create '{"NetworkingConfig":{"EndpointsConfig":{"bridge":{},"mynet":{}}}}'
    assert_output --partial "allow"
    create '{"HostConfig":{"Binds":["pgdata:/var/lib/postgresql/data"]}}'
    assert_output --partial "deny: volume pgdata was not created"
    create '{"HostConfig":{"Mounts":[{"Type":"volume","Source":"pgdata","Target":"/x"}]}}'
    assert_output --partial "deny: volume pgdata"
    create '{"HostConfig":{"Binds":["myvol:/x","/work/src:/src:ro"]}}'
    assert_output --partial "allow"
}

@test "a new named volume is created with the owner label first" {
    create '{"HostConfig":{"Binds":["fresh:/x"]}}'
    assert_output --partial "allow"
    assert_output --partial '"Name": "fresh", "Labels": {"ai-agent-sandbox.owner": "/work"}'
}

@test "inline volume driver options and unknown mount types are refused" {
    create '{"HostConfig":{"Mounts":[{"Type":"volume","Target":"/x","VolumeOptions":{"DriverConfig":{"Options":{"type":"ext4","device":"/dev/sda1"}}}}]}}'
    assert_output --partial "deny: inline volume driver options"
    create '{"HostConfig":{"Mounts":[{"Type":"npipe","Source":"x","Target":"/x"}]}}'
    assert_output --partial "deny: mount type npipe"
    create '{"HostConfig":{"Mounts":[{"Type":"tmpfs","Target":"/x"},{"Type":"bind","Source":"/work/a","Target":"/a"}]}}'
    assert_output --partial "allow"
}

# --- Other endpoints ------------------------------------------------------------------

@test "operations on existing containers require ownership" {
    local target
    for target in /v1.41/containers/theirs/json /v1.41/containers/theirs/exec \
        /v1.41/containers/theirs/archive /v1.41/containers/theirs /v1.41/containers/proxy/attach; do
        filter_check GET "$target"
        assert_output --partial "deny: container"
    done
    filter_check POST /v1.41/containers/mine/start
    assert_output --partial "allow"
    filter_check POST /v1.41/exec/e1/start '{}'
    assert_output --partial "allow"
    filter_check POST /v1.41/exec/e2/start '{}'
    assert_output --partial "deny: container theirs"
    filter_check POST "/v1.41/commit?container=theirs"
    assert_output --partial "deny: container theirs"
}

@test "privileged exec is refused" {
    filter_check POST /v1.41/containers/mine/exec '{"Cmd":["sh"],"Privileged":true}'
    assert_output --partial "deny: privileged exec"
    filter_check POST /v1.41/containers/mine/exec '{"Cmd":["sh"],"privileged":true}'
    assert_output --partial "deny: field privileged"
}

@test "lists, prunes and events only see the sandbox's own objects" {
    filter_check GET '/v1.41/containers/json?all=1&filters=%7B%22label%22%3A%5B%22com.docker.compose.project%3Dx%22%5D%7D'
    assert_output --partial 'com.docker.compose.project%3Dx'
    assert_output --partial 'ai-agent-sandbox.owner%3D%2Fwork'
    local target
    for target in /v1.41/volumes /v1.41/events; do
        filter_check GET "$target"
        assert_output --partial 'ai-agent-sandbox.owner%3D%2Fwork'
    done
    for target in /v1.41/containers/prune /v1.41/volumes/prune /v1.41/networks/prune; do
        filter_check POST "$target"
        assert_output --partial 'ai-agent-sandbox.owner%3D%2Fwork'
    done
}

@test "volume creation: local driver, tmpfs and bind options only" {
    filter_check POST /v1.41/volumes/create '{"Name":"v","DriverOpts":{"type":"tmpfs","device":"tmpfs","o":"size=100m"}}'
    assert_output --partial '"ai-agent-sandbox.owner": "/work"'
    filter_check POST /v1.41/volumes/create '{"Name":"v","DriverOpts":{"type":"none","o":"bind","device":"/work/data"}}'
    assert_output --partial "allow"
    local opts
    for opts in '{"type":"ext4","device":"/dev/nvme0n1p1"}' '{"type":"nfs","o":"addr=10.0.0.1","device":":/export"}' \
        '{"type":"cifs","device":"//nas/share"}' '{"device":"/dev/sda"}'; do
        filter_check POST /v1.41/volumes/create "{\"Name\":\"v\",\"DriverOpts\":$opts}"
        assert_output --partial "deny: volume driver options"
    done
    filter_check POST /v1.41/volumes/create '{"Name":"v","Driver":"rexray"}'
    assert_output --partial "deny: volume driver rexray"
    filter_check DELETE /v1.41/volumes/pgdata
    assert_output --partial "deny: volume pgdata"
    filter_check DELETE /v1.41/volumes/myvol
    assert_output --partial "allow"
}

@test "network creation: bridge driver only, connections to own networks" {
    filter_check POST /v1.41/networks/create '{"Name":"n"}'
    assert_output --partial '"ai-agent-sandbox.owner": "/work"'
    local driver
    for driver in macvlan ipvlan overlay host; do
        filter_check POST /v1.41/networks/create "{\"Name\":\"n\",\"Driver\":\"$driver\"}"
        assert_output --partial "deny: network driver $driver"
    done
    filter_check POST /v1.41/networks/create '{"Name":"n","Options":{"com.docker.network.bridge.name":"docker0"}}'
    assert_output --partial "deny:"
    filter_check POST /v1.41/networks/theirnet/connect '{"Container":"mine"}'
    assert_output --partial "deny: network theirnet"
    filter_check POST /v1.41/networks/mynet/connect '{"Container":"theirs"}'
    assert_output --partial "deny: container theirs"
    filter_check POST /v1.41/networks/mynet/connect '{"Container":"mine"}'
    assert_output --partial "allow"
    filter_check GET /v1.41/networks/bridge
    assert_output --partial "allow"
    filter_check DELETE /v1.41/networks/theirnet
    assert_output --partial "deny:"
}

@test "plugins, swarm, host-network builds and unknown endpoints are refused" {
    local target
    for target in /v1.41/plugins/pull /v1.41/swarm/init /v1.41/services/create /v1.41/secrets/create \
        /v1.41/system/df /v1.41/nonsense '/v1.41/build?networkmode=host' '/v1.41/build?networkmode=HOST'; do
        filter_check POST "$target"
        assert_output --partial "deny:"
    done
    filter_check PATCH /v1.41/containers/mine/json
    assert_output --partial "deny: method PATCH"
    for target in /_ping /v1.41/version /v1.41/info /v1.41/images/json /v1.41/plugins; do
        filter_check GET "$target"
        assert_output --partial "allow"
    done
    for target in /session /grpc '/v1.41/build?t=x' /v1.41/images/create; do
        filter_check POST "$target"
        assert_output --partial "allow"
    done
}

@test "paths that could be read differently by the daemon are refused" {
    local target
    for target in /v1.41/containers/../containers/create /v1.41//containers/create \
        http://evil/v1.41/containers/create; do
        filter_check POST "$target" '{}'
        assert_output --partial "deny:"
    done
    # a trailing slash is still checked as the create endpoint
    filter_check POST /v1.41/containers/create/ '{"HostConfig":{"Privileged":true}}'
    assert_output --partial "deny: privileged"
}

# --- HTTP relay ---------------------------------------------------------------------------

# Starts the filter against a fake upstream that answers every request with a
# chunked body naming the request it saw, except: /session switches to a raw
# echo stream, a path containing /close answers without framing. Sets
# FILTER_SOCKET.
start_relay() {
    cat > "$BATS_TEST_TMPDIR/upstream.py" <<'EOF'
import asyncio, sys
async def handle(reader, writer):
    while True:
        try:
            head = await reader.readuntil(b"\r\n\r\n")
        except asyncio.IncompleteReadError:
            break
        lines = head.decode().split("\r\n")
        path = lines[0].split()[1]
        headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        body = await reader.readexactly(int(headers["content-length"])) if "content-length" in headers else b""
        if "transfer-encoding" in headers:
            while True:
                size = int((await reader.readuntil(b"\r\n")).strip(), 16)
                # the 0 chunk is followed by the final empty line
                body += (await reader.readexactly(size + 2))[:-2]
                if size == 0:
                    break
        if path == "/session":
            writer.write(b"HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
            while True:
                data = await reader.read(100)
                if not data:
                    break
                writer.write(b"echo:" + data)
                await writer.drain()
            writer.close()
            return
        text = ("%s body=%s" % (lines[0], body.decode())).encode()
        if "/close" in path:
            writer.write(b"HTTP/1.1 200 OK\r\n\r\n" + text)
            writer.close()
            return
        writer.write(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n0\r\n\r\n" % (len(text), text))
        await writer.drain()
    writer.close()
async def main():
    server = await asyncio.start_unix_server(handle, path=sys.argv[1])
    async with server:
        await server.serve_forever()
asyncio.run(main())
EOF
    UPSTREAM_SOCKET="$BATS_TEST_TMPDIR/up.sock"
    FILTER_SOCKET="$BATS_TEST_TMPDIR/filter.sock"
    python3 -I "$BATS_TEST_TMPDIR/upstream.py" "$UPSTREAM_SOCKET" &
    UPSTREAM_PID=$!
    while [[ ! -S "$UPSTREAM_SOCKET" ]]; do sleep 0.05; done
    python3 -I "$BATS_TEST_TMPDIR/docker_filter.py" "$FILTER_SOCKET" "$UPSTREAM_SOCKET" /work 2>"$BATS_TEST_TMPDIR/filter.log" &
    FILTER_PID=$!
    while [[ ! -S "$FILTER_SOCKET" ]]; do sleep 0.05; done
}

teardown() {
    [[ -z "${FILTER_PID:-}" ]] || kill "$FILTER_PID" 2>/dev/null || true
    [[ -z "${UPSTREAM_PID:-}" ]] || kill "$UPSTREAM_PID" 2>/dev/null || true
}

# Usage: send <raw request bytes (printf format)>; prints what came back
send() {
    printf "$1" | python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(5)
s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read())
s.shutdown(socket.SHUT_WR)
out = b""
while True:
    try:
        data = s.recv(65536)
    except socket.timeout:
        break
    if not data:
        break
    out += data
sys.stdout.write(out.decode("latin-1"))
' "$FILTER_SOCKET"
}

@test "relay: the filter socket is private to the user" {
    start_relay
    run stat -c %a "$FILTER_SOCKET"
    assert_output 600
}

@test "relay: keep-alive requests are each checked, a denial closes the connection" {
    start_relay
    run send 'GET /v1.41/version HTTP/1.1\r\nHost: d\r\n\r\nPOST /v1.41/containers/create HTTP/1.1\r\nHost: d\r\nContent-Length: 35\r\n\r\n{"HostConfig":{"Privileged":true}}\nGET /v1.41/info HTTP/1.1\r\nHost: d\r\n\r\n'
    assert_output --partial "GET /v1.41/version HTTP/1.1 body="
    assert_output --partial "403 Forbidden"
    assert_output --partial "privileged containers are not allowed"
    refute_output --partial "/v1.41/info"
    refute_output --partial "containers/create HTTP/1.1 body"
}

@test "relay: rewritten bodies, chunked requests and responses without framing" {
    start_relay
    run send 'POST /v1.41/containers/create HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{"Image":"alpine\r\n2\r\n"}\r\n0\r\n\r\nGET /v1.41/images/close HTTP/1.1\r\nHost: d\r\n\r\n'
    assert_output --partial '"ai-agent-sandbox.owner": "/work"'
    assert_output --partial '"CapDrop": ["MKNOD"]'
    assert_output --partial "GET /v1.41/images/close HTTP/1.1 body="
}

@test "relay: a chunked upload to an uninspected endpoint is passed through as parsed" {
    start_relay
    run send 'POST /v1.41/build HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'
    assert_output --partial "POST /v1.41/build HTTP/1.1 body=hello world"
}

@test "relay: request smuggling attempts are refused" {
    start_relay
    run send 'POST /v1.41/build HTTP/1.1\r\nHost: d\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n'
    assert_output --partial "unsupported transfer encoding"
    run send 'POST /v1.41/build HTTP/1.1\r\nHost: d\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nabcde'
    assert_output --partial "duplicate Content-Length"
    run send 'POST /v1.41/build HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n'
    assert_output --partial "unsupported transfer encoding"
    # an uninspected upload is streamed: a broken chunk ends the connection
    # without forwarding it (the head already went upstream, so no 403)
    run send 'POST /v1.41/build HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nGET /v1.41/info HTTP/1.1\r\n\r\n'
    refute_output --partial "body="
    refute_output --partial "200 OK"
    run send 'GET /v1.41/version HTTP/1.1\r\nHost: d\r\n X-Folded: x\r\n\r\n'
    assert_output --partial "malformed header"
}

@test "relay: after a protocol switch the connection is a raw stream" {
    start_relay
    run send 'POST /session HTTP/1.1\r\nHost: d\r\nUpgrade: h2c\r\nConnection: Upgrade\r\n\r\nraw stdin bytes'
    assert_output --partial "101 UPGRADED"
    assert_output --partial "echo:raw stdin bytes"
}
