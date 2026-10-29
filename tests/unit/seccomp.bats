#!/usr/bin/env bats
# Syscall filter: the BPF assembler, the generated programs (run through a
# small classic-BPF interpreter below, so no kernel is involved), the syscall
# tables, the level ranking and the rule that project files may only tighten
# the filter. The real kernel behaviour is covered in tests/integration.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    FILTER="$BATS_TEST_TMPDIR/filter.bpf"
}

# Usage: seccomp_eval <file> <abi|0xARCH> <nr> [arg0] [arg1]
# Runs the program on one seccomp_data record and prints ALLOW, EPERM, ENOSYS
# or the raw return value. Supports the instructions build_seccomp_filter uses.
seccomp_eval() {
    local file="$1" arch="$2" nr=$(($3)) arg0=$((${4:-0})) arg1=$((${5:-0}))
    [[ "$arch" == 0x* ]] || arch="${SECCOMP_AUDIT_ARCH[$arch]}"
    local -a b
    read -r -a b <<< "$(od -An -v -tu1 "$file" | tr -s ' \n' '  ')"
    local pc=0 acc=0 code jt jf k steps=0
    while (( pc * 8 < ${#b[@]} && steps++ < 10000 )); do
        local o=$((pc * 8))
        code=$((b[o] | b[o + 1] << 8)) jt=${b[o + 2]} jf=${b[o + 3]}
        k=$((b[o + 4] | b[o + 5] << 8 | b[o + 6] << 16 | b[o + 7] << 24))
        pc=$((pc + 1))
        case "$code" in
            32) # ld [k]
                case "$k" in
                    0) acc=$((nr & 0xffffffff)) ;;
                    4) acc=$((arch)) ;;
                    16) acc=$((arg0 & 0xffffffff)) ;;
                    20) acc=$((arg0 >> 32 & 0xffffffff)) ;;
                    24) acc=$((arg1 & 0xffffffff)) ;;
                    28) acc=$((arg1 >> 32 & 0xffffffff)) ;;
                    *) echo "bad load offset $k"; return 1 ;;
                esac ;;
            21) (( acc == k )) && pc=$((pc + jt)) || pc=$((pc + jf)) ;;
            53) (( acc >= k )) && pc=$((pc + jt)) || pc=$((pc + jf)) ;;
            69) (( acc & k )) && pc=$((pc + jt)) || pc=$((pc + jf)) ;;
            6)
                if (( k == SECCOMP_RET_ALLOW )); then echo ALLOW
                elif (( k == SECCOMP_RET_EPERM )); then echo EPERM
                elif (( k == SECCOMP_RET_ENOSYS )); then echo ENOSYS
                else printf '0x%x\n' "$k"
                fi
                return 0 ;;
            *) echo "bad opcode $code"; return 1 ;;
        esac
    done
    echo "fell off the program"
    return 1
}

# Usage: assert_verdict <expected> <abi> <nr> [args...]
assert_verdict() {
    local expected="$1"
    shift
    run seccomp_eval "$FILTER" "$@"
    assert_success
    assert_output "$expected"
}

# --- Levels ---------------------------------------------------------------------

@test "seccomp_level_rank orders off < default < strict and rejects other values" {
    assert_equal "$(seccomp_level_rank off)" 0
    assert_equal "$(seccomp_level_rank default)" 1
    assert_equal "$(seccomp_level_rank strict)" 2
    run seccomp_level_rank on
    assert_failure
}

# --- Assembler ------------------------------------------------------------------

@test "the assembler encodes instructions little-endian and resolves labels" {
    local -a _SECCOMP_PROG=()
    local -A _SECCOMP_LABELS=()
    seccomp_asm 0x20 - - 4
    seccomp_asm 0x15 deny - 0xc000003e
    seccomp_asm 0x06 - - 0x7fff0000
    seccomp_asm_label deny
    seccomp_asm 0x06 - - 0x50001
    seccomp_asm_write "$FILTER"
    run od -An -v -tx1 "$FILTER"
    assert_output "$(printf ' %s\n' \
        '20 00 00 00 04 00 00 00 15 00 01 00 3e 00 00 c0' \
        '06 00 00 00 00 00 ff 7f 06 00 00 00 01 00 05 00')"
}

@test "the assembler refuses unknown labels and jumps beyond 255 instructions" {
    local -a _SECCOMP_PROG=()
    local -A _SECCOMP_LABELS=()
    seccomp_asm 0x15 nowhere - 1
    run seccomp_asm_write "$FILTER"
    assert_failure
    assert_output --partial "unknown label nowhere"

    _SECCOMP_PROG=()
    local i
    seccomp_asm 0x15 far - 1
    for ((i = 0; i < 256; i++)); do seccomp_asm 0x06 - - 0; done
    seccomp_asm_label far
    seccomp_asm 0x06 - - 0
    run seccomp_asm_write "$FILTER"
    assert_failure
    assert_output --partial "out of range"
}

# --- default level ----------------------------------------------------------------

@test "default: exploit-prone syscalls are refused, ordinary ones allowed" {
    build_seccomp_filter default "$FILTER" x86_64 i386
    assert_verdict EPERM x86_64 250   # keyctl
    assert_verdict EPERM x86_64 321   # bpf
    assert_verdict EPERM x86_64 323   # userfaultfd
    assert_verdict EPERM x86_64 298   # perf_event_open
    assert_verdict EPERM x86_64 313   # finit_module
    assert_verdict ALLOW x86_64 39    # getpid
    assert_verdict ALLOW x86_64 0     # read
    assert_verdict ALLOW x86_64 59    # execve
    assert_verdict ALLOW x86_64 101   # ptrace (confined by the PID namespace)
}

@test "default: io_uring reports ENOSYS so runtimes fall back" {
    build_seccomp_filter default "$FILTER" x86_64 i386
    assert_verdict ENOSYS x86_64 425
    assert_verdict ENOSYS x86_64 426
    assert_verdict ENOSYS x86_64 427
}

@test "default: TIOCSTI and TIOCLINUX are refused, other ioctls allowed" {
    build_seccomp_filter default "$FILTER" x86_64 i386
    assert_verdict EPERM x86_64 16 0 0x5412
    assert_verdict EPERM x86_64 16 0 0x541c
    # the tty layer only looks at the low 32 bits of the request
    assert_verdict EPERM x86_64 16 0 0x100005412
    assert_verdict ALLOW x86_64 16 0 0x5401   # TCGETS
    assert_verdict ALLOW x86_64 16 0x5412 0   # the value in the fd argument
}

@test "default: only the usual personalities are allowed" {
    build_seccomp_filter default "$FILTER" x86_64 i386
    assert_verdict ALLOW x86_64 135 0
    assert_verdict ALLOW x86_64 135 0xffffffff
    assert_verdict ALLOW x86_64 135 0x8
    assert_verdict EPERM x86_64 135 0x0040000   # ADDR_NO_RANDOMIZE
    assert_verdict EPERM x86_64 135 0x0400000   # READ_IMPLIES_EXEC
}

@test "default: user namespaces and mounts stay available (nested sandboxes)" {
    build_seccomp_filter default "$FILTER" x86_64 i386
    assert_verdict ALLOW x86_64 272                # unshare
    assert_verdict ALLOW x86_64 56 0x10000000      # clone(CLONE_NEWUSER)
    assert_verdict ALLOW x86_64 435                # clone3
    assert_verdict ALLOW x86_64 165                # mount
}

@test "foreign ABIs are refused: x32 numbers and unknown architectures" {
    build_seccomp_filter default "$FILTER" x86_64 i386
    assert_verdict EPERM x86_64 $((0x40000000 + 39))
    assert_verdict EPERM 0x40000028 20             # 32-bit ARM
    build_seccomp_filter default "$FILTER" aarch64
    assert_verdict EPERM x86_64 39
}

@test "i386 uses its own syscall numbers" {
    build_seccomp_filter default "$FILTER" x86_64 i386
    assert_verdict EPERM i386 288     # keyctl
    assert_verdict EPERM i386 166     # vm86
    assert_verdict ENOSYS i386 425    # io_uring_setup
    assert_verdict EPERM i386 54 0 0x5412
    assert_verdict ALLOW i386 250     # fadvise64 (keyctl on x86_64)
    assert_verdict ALLOW i386 20      # getpid
}

@test "aarch64 uses the generic syscall numbers" {
    build_seccomp_filter default "$FILTER" aarch64
    assert_verdict EPERM aarch64 219  # keyctl
    assert_verdict EPERM aarch64 280  # bpf
    assert_verdict EPERM aarch64 29 0 0x5412
    assert_verdict ALLOW aarch64 172  # getpid
    assert_verdict ALLOW aarch64 250  # keyctl on x86_64, unused here
}

# --- strict level -------------------------------------------------------------------

@test "strict: new user namespaces, namespace switches and mounts are refused" {
    build_seccomp_filter strict "$FILTER" x86_64 i386
    assert_verdict EPERM x86_64 272                    # unshare
    assert_verdict EPERM x86_64 308                    # setns
    assert_verdict EPERM x86_64 56 0x10000011          # clone(CLONE_NEWUSER|SIGCHLD)
    assert_verdict ALLOW x86_64 56 0x11                # fork-like clone
    assert_verdict ALLOW x86_64 56 0x003d0f00          # pthread_create
    assert_verdict ENOSYS x86_64 435                   # clone3
    assert_verdict EPERM x86_64 165                    # mount
    assert_verdict EPERM x86_64 430                    # fsopen
    assert_verdict EPERM x86_64 161                    # chroot
    assert_verdict EPERM i386 120 0x10000000           # clone on i386
    assert_verdict EPERM i386 22                       # umount (i386 only)
    assert_verdict EPERM x86_64 250                    # still keyctl
    assert_verdict ALLOW x86_64 39
}

@test "strict for aarch64 stays within the jump range" {
    build_seccomp_filter strict "$FILTER" aarch64
    assert_verdict EPERM aarch64 220 0x10000000
    assert_verdict EPERM aarch64 97
}

# --- Syscall tables ---------------------------------------------------------------

@test "every filtered name exists in the x86_64 table, the generic table, or is ABI-specific" {
    local name
    local -a all=("${SECCOMP_EPERM_DEFAULT[@]}" "${SECCOMP_ENOSYS_DEFAULT[@]}"
        "${SECCOMP_EPERM_STRICT[@]}" "${SECCOMP_ENOSYS_STRICT[@]}" ioctl personality clone)
    for name in "${all[@]}"; do
        [[ -n "${SECCOMP_NR_x86_64[$name]:-}${SECCOMP_NR_i386[$name]:-}${SECCOMP_NR_aarch64[$name]:-}" ]] \
            || fail "$name is in no table"
    done
}

@test "the syscall tables agree with libseccomp" {
    command -v python3 >/dev/null || skip "python3 is not installed"
    python3 -c 'import ctypes; ctypes.CDLL("libseccomp.so.2")' 2>/dev/null || skip "libseccomp is not installed"
    local abi name expected=""
    for abi in x86_64 i386 aarch64; do
        local -n table="SECCOMP_NR_$abi"
        for name in "${!table[@]}"; do
            expected+="$abi $name ${table[$name]}"$'\n'
        done
        unset -n table
    done
    run python3 -I -c '
import ctypes, sys
lib = ctypes.CDLL("libseccomp.so.2")
lib.seccomp_syscall_resolve_name_arch.argtypes = [ctypes.c_uint32, ctypes.c_char_p]
arches = {"x86_64": 0xc000003e, "i386": 0x40000003, "aarch64": 0xc00000b7}
for line in sys.stdin.read().split("\n"):
    if not line:
        continue
    abi, name, nr = line.split()
    got = lib.seccomp_syscall_resolve_name_arch(arches[abi], name.encode())
    # libseccomp releases older than the kernel do not know the newest calls
    if got < 0 and int(nr) >= 460:
        continue
    if got != int(nr):
        print(f"{abi} {name}: table {nr}, libseccomp {got}")
' <<< "$expected"
    assert_success
    assert_output ""
}

# --- Configuration --------------------------------------------------------------------

@test "a user-level file may switch the filter off" {
    apply_config_scalar seccomp off "$DEFAULT_CONFIG_FILE" false
    assert_equal "$SECCOMP_LEVEL" off
    assert_equal "$SECCOMP_SOURCE" "$DEFAULT_CONFIG_FILE"
}

@test "a project file may tighten the filter" {
    apply_config_scalar seccomp strict "$PROJECT_CONFIG_DIR/config.yaml" false
    assert_equal "$SECCOMP_LEVEL" strict
    assert_equal "$SECCOMP_SOURCE" "$PROJECT_CONFIG_DIR/config.yaml"
}

@test "a project file cannot loosen the filter" {
    apply_config_scalar seccomp off "$PROJECT_CONFIG_DIR/config.yaml" false
    assert_equal "$SECCOMP_LEVEL" ""
    assert_equal "$SECCOMP_SOURCE" default
    [[ "${CONFIG_LOG_MESSAGES[*]}" == *"may only tighten"* ]] || fail "no warning: ${CONFIG_LOG_MESSAGES[*]}"

    apply_config_scalar seccomp strict "$DEFAULT_CONFIG_FILE" false
    apply_config_scalar seccomp default "$PROJECT_CONFIG_DIR/config.local.yaml" false
    assert_equal "$SECCOMP_LEVEL" strict
    apply_config_scalar seccomp "" "$PROJECT_CONFIG_DIR/config.yaml" true
    assert_equal "$SECCOMP_LEVEL" strict
}

@test "an invalid seccomp value is fatal" {
    run apply_config_scalar seccomp on "$DEFAULT_CONFIG_FILE" false
    assert_failure
    assert_output --partial "expected off, default or strict"
}

# --- resolve_seccomp_level --------------------------------------------------------------

@test "the default level is filled in with the host's ABIs" {
    stub_command uname 'echo x86_64'
    resolve_seccomp_level
    assert_equal "$SECCOMP_LEVEL" default
    assert_equal "${SECCOMP_ARCHES[*]}" "x86_64 i386"
}

@test "an unsupported architecture switches the default off with a warning" {
    stub_command uname 'echo riscv64'
    resolve_seccomp_level 2>"$BATS_TEST_TMPDIR/stderr"
    assert_equal "$SECCOMP_LEVEL" off
    assert_equal "$SECCOMP_SOURCE" fallback
    run cat "$BATS_TEST_TMPDIR/stderr"
    assert_output --partial "No syscall filter for architecture riscv64"
}

@test "an explicit level on an unsupported architecture is fatal" {
    stub_command uname 'echo riscv64'
    SECCOMP_LEVEL=strict SECCOMP_SOURCE=--seccomp
    run resolve_seccomp_level
    assert_failure
    assert_output --partial "not available for architecture riscv64"
}

@test "open_seccomp_filter leaves no file behind" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    SECCOMP_LEVEL=default SECCOMP_ARCHES=(x86_64 i386)
    open_seccomp_filter
    [[ -n "$SECCOMP_FD" ]]
    run ls -A "$TMPDIR"
    assert_output ""
    cat <&"$SECCOMP_FD" > "$FILTER"
    exec {SECCOMP_FD}<&-
    assert_verdict EPERM x86_64 250
}
