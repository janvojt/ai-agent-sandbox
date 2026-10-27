#!/usr/bin/env bats
# Network isolation helpers: choosing the mode and checking its tools, the
# generated resolv.conf and DNS forwarding, the host's on-link subnets that
# get blocked, and allow_hosts resolution. No real pasta or network namespace
# is started; tools are stubs on PATH.
#
# host_nameservers and prepare_isolated_network read /etc/resolv.conf directly
# (no override), so those tests bind a fixture over it in a private mount
# namespace (`unshare --user --map-root-user --mount`) and source the script
# there. They are skipped where unprivileged user namespaces are unavailable.

setup() {
    load ../test_helper/common
    setup_test_env
    export SANDBOX_SCRIPT
    export TMPDIR="$BATS_TEST_TMPDIR"
    # A directory with only the external tools the functions need besides the
    # stubs, so that the host's pasta/nsenter/unshare/ip are not found
    BASE_BIN="$BATS_TEST_TMPDIR/base-bin"
    mkdir -p "$BASE_BIN"
    local tool
    for tool in grep awk sort cat bash; do
        ln -s "$(command -v "$tool")" "$BASE_BIN/$tool"
    done
    load_sandbox_script
}

# Stubs for every tool isolated mode needs, with help texts of current versions
stub_network_tools() {
    stub_command pasta
    stub_command nsenter
    stub_command unshare 'echo "     --map-user=<uid>|<name>  map current user to uid"'
    stub_command ip
}

# Run resolve_network_mode with PATH limited to the stubs and the base tools
resolve_with_stubs() {
    PATH="$STUB_DIR:$BASE_BIN" resolve_network_mode
}

# --- resolve_network_mode --------------------------------------------------------

@test "without a mode the default isolated mode is used when all tools exist" {
    stub_network_tools
    resolve_with_stubs
    assert_equal "$NETWORK_MODE" isolated
    assert_equal "$NETWORK_MODE_SOURCE" default
    assert_equal "$PASTA_BIN" "$STUB_DIR/pasta"
    assert_equal "$NSENTER_BIN" "$STUB_DIR/nsenter"
    assert_equal "$UNSHARE_BIN" "$STUB_DIR/unshare"
    assert_equal "$IP_BIN" "$STUB_DIR/ip"
}

@test "the default falls back to the host network without pasta" {
    stub_network_tools
    rm "$STUB_DIR/pasta"
    resolve_with_stubs 2>"$BATS_TEST_TMPDIR/stderr"
    assert_equal "$NETWORK_MODE" host
    assert_equal "$NETWORK_MODE_SOURCE" fallback
    run cat "$BATS_TEST_TMPDIR/stderr"
    assert_output --partial "pasta (package passt)"
    assert_output --partial "falling back to the host network"
}

@test "an explicitly requested isolated mode without pasta is fatal" {
    stub_network_tools
    rm "$STUB_DIR/pasta"
    NETWORK_MODE=isolated
    NETWORK_MODE_SOURCE=--network
    run resolve_with_stubs
    assert_failure 1
    assert_output --partial "network isolation (from --network) needs pasta (package passt)"
}

@test "isolated mode from a config file without pasta is fatal as well" {
    stub_network_tools
    rm "$STUB_DIR/pasta"
    NETWORK_MODE=isolated
    NETWORK_MODE_SOURCE="$PROJECT_CONFIG_FILE"
    run resolve_with_stubs
    assert_failure 1
    assert_output --partial "Error: network isolation"
}

@test "an nsenter without --keep-caps (util-linux < 2.40) is enough" {
    stub_network_tools
    stub_command nsenter 'echo "  -F, --no-fork  do not fork before exec'\''ing <program>"'
    NETWORK_MODE=isolated
    NETWORK_MODE_SOURCE=--network
    resolve_with_stubs
    assert_equal "$NETWORK_MODE" isolated
}

@test "a missing nsenter is fatal for an explicit isolated mode" {
    stub_network_tools
    rm "$STUB_DIR/nsenter"
    NETWORK_MODE=isolated
    NETWORK_MODE_SOURCE=--network
    run resolve_with_stubs
    assert_failure 1
    assert_output --partial "nsenter (package util-linux)"
}

@test "an unshare without --map-user counts as missing" {
    stub_network_tools
    stub_command unshare 'echo "  -r, --map-root-user  map current user to root"'
    resolve_with_stubs 2>"$BATS_TEST_TMPDIR/stderr"
    assert_equal "$NETWORK_MODE" host
    assert_equal "$NETWORK_MODE_SOURCE" fallback
    run cat "$BATS_TEST_TMPDIR/stderr"
    assert_output --partial "unshare with --map-user (util-linux >= 2.38)"
}

@test "missing ip, nsenter and unshare are all reported" {
    stub_command pasta
    NETWORK_MODE=isolated
    NETWORK_MODE_SOURCE=AI_AGENT_SANDBOX_NETWORK
    run resolve_with_stubs
    assert_failure 1
    assert_output --partial "unshare (package util-linux)"
    assert_output --partial "nsenter (package util-linux)"
    assert_output --partial "ip (package iproute2)"
    refute_output --partial "pasta"
}

@test "host and none modes need no tools" {
    NETWORK_MODE=host
    NETWORK_MODE_SOURCE=--network
    resolve_with_stubs
    assert_equal "$NETWORK_MODE" host
    assert_equal "$NETWORK_MODE_SOURCE" --network
    assert_equal "$PASTA_BIN" ""
    NETWORK_MODE=none
    resolve_with_stubs
    assert_equal "$NETWORK_MODE" none
}

@test "host ports and allowed hosts are deduplicated" {
    NETWORK_MODE=host
    NETWORK_HOST_PORTS=(3773 8080 3773)
    NETWORK_ALLOW_HOSTS=(10.0.0.1 nas.lan 10.0.0.1)
    resolve_with_stubs
    assert_equal "${NETWORK_HOST_PORTS[*]}" "3773 8080"
    assert_equal "${NETWORK_ALLOW_HOSTS[*]}" "10.0.0.1 nas.lan"
}

# --- host_nameservers and prepare_isolated_network (fixture resolv.conf) -------------

# Usage: run_with_resolv_conf <fixture-content> <bash code>
# Runs the code in a private mount namespace where the fixture is bound over
# /etc/resolv.conf, after sourcing the script there.
run_with_resolv_conf() {
    local fixture="$BATS_TEST_TMPDIR/resolv.conf.fixture"
    printf '%b' "$1" > "$fixture"
    unshare --user --map-root-user --mount true 2>/dev/null \
        || skip "unprivileged user and mount namespaces are not available"
    [[ -e /etc/resolv.conf ]] || skip "the host has no /etc/resolv.conf to bind over"
    run unshare --user --map-root-user --mount bash -c '
        mount --bind "$1" /etc/resolv.conf || exit 99
        source "$SANDBOX_SCRIPT"
        set +u +o pipefail
        BWRAP_ARGS=()
        eval "$2"' _ "$fixture" "$2"
    [[ "$status" -ne 99 ]] || skip "cannot bind a fixture over /etc/resolv.conf"
}

# Prints the generated resolv.conf, the forward arguments and BWRAP_ARGS
PREPARE_AND_DUMP='prepare_isolated_network
echo "--- resolv.conf"; cat "$NETWORK_TMP_DIR/resolv.conf"
echo "--- forward"; printf "%s\n" "${NETWORK_DNS_FORWARD_ARGS[@]}"
echo "--- bwrap"; printf "%s\n" "${BWRAP_ARGS[@]}"
[[ "$NETWORK_TMP_DIR" == "$TMPDIR"/ai-agent-sandbox-net.* ]] && echo "--- tmpdir ok"'

@test "host_nameservers separates IPv4 and IPv6 resolvers" {
    run_with_resolv_conf '# comment\nsearch lan\nnameserver 192.168.1.1\n  nameserver 8.8.8.8 # trailing\nnameserver 2001:4860:4860::8888\nnameserver fe80::1%wlan0\noptions edns0\n' \
        'echo "v4:$(host_nameservers 4 | tr "\n" " ")"; echo "v6:$(host_nameservers 6 | tr "\n" " ")"'
    assert_success
    assert_line "v4:192.168.1.1 8.8.8.8 "
    assert_line "v6:2001:4860:4860::8888 fe80::1%wlan0 "
}

@test "host_nameservers ignores commented-out and malformed lines" {
    run_with_resolv_conf '#nameserver 1.1.1.1\nnameservers 9.9.9.9\nnameserver\n' \
        'echo "v4:[$(host_nameservers 4)]"; echo "v6:[$(host_nameservers 6)]"'
    assert_success
    assert_line "v4:[]"
    assert_line "v6:[]"
}

@test "prepare_isolated_network replaces IPv4 resolvers with the forwarded sandbox address" {
    run_with_resolv_conf 'search lan\nnameserver 192.168.1.1\nnameserver 8.8.8.8\noptions edns0 trust-ad\n' "$PREPARE_AND_DUMP"
    assert_success
    assert_line "nameserver $NETWORK_DNS4"
    refute_line "nameserver 192.168.1.1"
    refute_line "nameserver 8.8.8.8"
    refute_line "nameserver $NETWORK_DNS6"
    assert_line "search lan"
    assert_line "options edns0 trust-ad"
    assert_line "--- tmpdir ok"
    run bash -c 'sed -n "/^--- forward/,/^--- bwrap/p" <<<"$1" | grep -c -- --dns-forward' _ "$output"
    assert_output 1
}

@test "prepare_isolated_network forwards exactly the DNS4 address and binds resolv.conf" {
    run_with_resolv_conf 'nameserver 1.1.1.1\n' "$PREPARE_AND_DUMP"
    assert_success
    local -a lines=("${lines[@]}")
    args_contain_sequence "--- forward" --dns-forward "$NETWORK_DNS4" "--- bwrap" --ro-bind -- "${lines[@]}" \
        || fail "unexpected output: $output"
    assert_line /etc/resolv.conf
    assert_line --regexp "^$BATS_TEST_TMPDIR/ai-agent-sandbox-net\.[^/]+/resolv\.conf$"
}

@test "prepare_isolated_network adds the IPv6 forward address when the host has an IPv6 resolver" {
    run_with_resolv_conf 'nameserver 192.0.2.53\nnameserver 2001:db8:ffff::53\n' "$PREPARE_AND_DUMP"
    assert_success
    assert_line "nameserver $NETWORK_DNS4"
    assert_line "nameserver $NETWORK_DNS6"
    refute_line "nameserver 2001:db8:ffff::53"
    local -a lines=("${lines[@]}")
    args_contain_sequence --dns-forward "$NETWORK_DNS4" --dns-forward "$NETWORK_DNS6" -- "${lines[@]}" \
        || fail "unexpected output: $output"
}

@test "prepare_isolated_network handles an IPv6-only resolver" {
    run_with_resolv_conf 'nameserver 2001:db8:ffff::53\n' "$PREPARE_AND_DUMP"
    assert_success
    assert_line "nameserver $NETWORK_DNS6"
    refute_line "nameserver $NETWORK_DNS4"
    refute_line --partial "--dns-forward $NETWORK_DNS4"
}

@test "prepare_isolated_network replaces a 127.0.0.53 stub resolver" {
    run_with_resolv_conf '# This is /run/systemd/resolve/stub-resolv.conf\nnameserver 127.0.0.53\noptions edns0 trust-ad\nsearch .\n' "$PREPARE_AND_DUMP"
    assert_success
    refute_line "nameserver 127.0.0.53"
    assert_line "nameserver $NETWORK_DNS4"
    assert_line "$NETWORK_DNS4"
    assert_line "options edns0 trust-ad"
}

@test "prepare_isolated_network drops indented nameserver lines too" {
    run_with_resolv_conf '  nameserver 10.0.0.1\n\tnameserver 10.0.0.2\nnameserver\n' "$PREPARE_AND_DUMP"
    assert_success
    refute_line --partial "10.0.0.1"
    refute_line --partial "10.0.0.2"
    refute_line "nameserver"
}

@test "prepare_isolated_network keeps a last line without newline" {
    run_with_resolv_conf 'nameserver 1.1.1.1\nsearch example.org' "$PREPARE_AND_DUMP"
    assert_success
    assert_line "search example.org"
}

@test "prepare_isolated_network warns and forwards nothing without a nameserver" {
    run_with_resolv_conf 'search lan\n' "$PREPARE_AND_DUMP"
    assert_success
    assert_line --partial "No nameserver in /etc/resolv.conf"
    refute_line --partial "nameserver $NETWORK_DNS4"
    refute_line --dns-forward
    assert_line /etc/resolv.conf
}

@test "the DNS4 address is inside the sandbox /24 and not its broadcast address" {
    [[ "$NETWORK_DNS4" == "${NETWORK_NS_ADDR4%.*/24}".* ]] || fail "$NETWORK_DNS4 outside $NETWORK_NS_ADDR4"
    [[ "${NETWORK_DNS4##*.}" != 255 ]] || fail "$NETWORK_DNS4 is the broadcast address"
    [[ "$NETWORK_DNS4" != "${NETWORK_NS_ADDR4%/*}" && "$NETWORK_DNS4" != "$NETWORK_GW4" ]] \
        || fail "$NETWORK_DNS4 collides with the namespace or gateway address"
}

# --- host_onlink_subnets ---------------------------------------------------------

stub_ip_routes() {
    cat > "$BATS_TEST_TMPDIR/routes4" <<'EOF'
default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.50 metric 600
0.0.0.0/1 dev tun0 scope link
128.0.0.0/1 dev tun0 scope link
10.8.0.0/24 dev tun0 proto kernel scope link src 10.8.0.2
44.0.0.0/8 dev eth2 scope link
45.0.0.0/7 dev eth3 scope link
127.0.0.0/8 dev lo scope host
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.50 metric 600
198.51.100.0/24 dev eth1 proto kernel scope link src 198.51.100.7
203.0.113.0/24 via 10.8.0.1 dev tun0
blackhole 192.0.2.0/24
unreachable 192.0.2.128/25
EOF
    cat > "$BATS_TEST_TMPDIR/routes6" <<'EOF'
::1 dev lo proto kernel metric 256 pref medium
::/1 dev tun0 metric 1024 pref medium
8000::/1 dev tun0 metric 1024 pref medium
2001:db8::/15 dev eth5 metric 1024 pref medium
2001:db8::/16 dev eth4 metric 1024 pref medium
2001:db8:1::/64 dev wlan0 proto ra metric 600 pref medium
2001:db8:2::/48 via fe80::1 dev wlan0 metric 1024 pref medium
fd00:1::/64 dev wg0 proto kernel metric 256 pref medium
fe80::/64 dev wlan0 proto kernel metric 1024 pref medium
default via fe80::1 dev wlan0 proto ra metric 600 pref medium
EOF
    stub_command ip "case \"\$1 \$2 \$3\" in
    '-4 route show') cat '$BATS_TEST_TMPDIR/routes4' ;;
    '-6 route show') cat '$BATS_TEST_TMPDIR/routes6' ;;
    *) echo \"unexpected ip \$*\" >&2; exit 1 ;;
esac"
    IP_BIN="$STUB_DIR/ip"
}

@test "host_onlink_subnets lists on-link IPv4 subnets of at least /8" {
    stub_ip_routes
    run host_onlink_subnets 4
    assert_success
    assert_output "10.8.0.0/24
44.0.0.0/8
172.17.0.0/16
192.168.1.0/24
198.51.100.0/24"
}

@test "host_onlink_subnets leaves a VPN's /1 routes, gateway routes and loopback open" {
    stub_ip_routes
    run host_onlink_subnets 4
    refute_line 0.0.0.0/1
    refute_line 128.0.0.0/1
    refute_line 45.0.0.0/7
    refute_line 203.0.113.0/24
    refute_line 127.0.0.0/8
    refute_line --partial default
}

@test "host_onlink_subnets ignores typed routes such as blackhole and unreachable" {
    stub_ip_routes
    run host_onlink_subnets 4
    refute_line --partial 192.0.2.
}

@test "host_onlink_subnets lists on-link IPv6 prefixes of at least /16" {
    stub_ip_routes
    run host_onlink_subnets 6
    assert_success
    assert_output "2001:db8::/16
2001:db8:1::/64
fd00:1::/64"
}

@test "host_onlink_subnets skips IPv6 link-local, loopback, short and routed prefixes" {
    stub_ip_routes
    run host_onlink_subnets 6
    refute_line fe80::/64
    refute_line --partial ::1
    refute_line ::/1
    refute_line 8000::/1
    refute_line 2001:db8::/15
    refute_line 2001:db8:2::/48
}

@test "host_onlink_subnets prints nothing when ip fails" {
    stub_command ip 'exit 1'
    IP_BIN="$STUB_DIR/ip"
    run host_onlink_subnets 4
    assert_success
    assert_output ""
}

@test "host_onlink_subnets blocks on-link host routes printed without a prefix length" {
    skip "BUG: on-link /32 host routes (ip prints them without /32, e.g. '203.0.113.1 dev eth0 scope link') are not blocked"
    printf '%s\n' "default via 203.0.113.1 dev eth0" "203.0.113.1 dev eth0 scope link" > "$BATS_TEST_TMPDIR/routes4"
    stub_command ip "cat '$BATS_TEST_TMPDIR/routes4'"
    IP_BIN="$STUB_DIR/ip"
    run host_onlink_subnets 4
    assert_output --regexp '^203\.0\.113\.1(/32)?$'
}

# --- resolve_allow_host ---------------------------------------------------------

stub_getent() {
    stub_command getent "echo \"\$*\" >> '$BATS_TEST_TMPDIR/getent.calls'
[[ \"\$1\" == ahosts ]] || exit 1
case \"\$2\" in
    nas.lan)
        printf '%s\n' '192.168.1.20    STREAM nas.lan' '192.168.1.20    DGRAM' '192.168.1.20    RAW' \
            'fd00::20        STREAM' 'fd00::20        DGRAM' ;;
    *) exit 2 ;;
esac"
}

@test "resolve_allow_host passes IPv4 addresses and CIDRs through without a lookup" {
    stub_getent
    run resolve_allow_host 192.168.1.20
    assert_output 192.168.1.20
    run resolve_allow_host 10.0.0.0/24
    assert_output 10.0.0.0/24
    assert_file_not_exists "$BATS_TEST_TMPDIR/getent.calls"
}

@test "resolve_allow_host passes IPv6 addresses and prefixes through without a lookup" {
    stub_getent
    run resolve_allow_host fd00::20
    assert_output fd00::20
    run resolve_allow_host 2001:db8::/64
    assert_output 2001:db8::/64
    run resolve_allow_host ::1
    assert_output ::1
    assert_file_not_exists "$BATS_TEST_TMPDIR/getent.calls"
}

@test "resolve_allow_host resolves a hostname to its unique addresses" {
    stub_getent
    run resolve_allow_host nas.lan
    assert_success
    assert_equal "${#lines[@]}" 2
    assert_line 192.168.1.20
    assert_line fd00::20
    run cat "$BATS_TEST_TMPDIR/getent.calls"
    assert_output "ahosts nas.lan"
}

@test "resolve_allow_host prints nothing for an unresolvable hostname" {
    stub_getent
    run resolve_allow_host does-not-exist.invalid
    assert_output ""
}

@test "resolve_allow_host looks up names that only resemble addresses" {
    stub_getent
    run resolve_allow_host 1.2.3
    assert_output ""
    run cat "$BATS_TEST_TMPDIR/getent.calls"
    assert_output "ahosts 1.2.3"
}
