#!/usr/bin/env bats
# The minimal /sys: an empty tmpfs plus the paths runtimes read and the
# sandbox's own cgroup. The cgroup files are fixtures (CGROUP_V2_ROOT,
# PROC_SELF_CGROUP), the real mount is covered in tests/integration.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    CGROUP_V2_ROOT="$BATS_TEST_TMPDIR/cgroup"
    PROC_SELF_CGROUP="$BATS_TEST_TMPDIR/self-cgroup"
    mkdir -p "$CGROUP_V2_ROOT"
    : > "$CGROUP_V2_ROOT/cgroup.controllers"
    BWRAP_ARGS=()
}

@test "/sys is an empty tmpfs with the CPU, NUMA and huge page directories" {
    printf '0::/\n' > "$PROC_SELF_CGROUP"
    mount_minimal_sys
    assert_equal "${BWRAP_ARGS[0]} ${BWRAP_ARGS[1]}" "--tmpfs /sys"
    assert_args_contain BWRAP_ARGS --ro-bind-try /sys/devices/system/cpu /sys/devices/system/cpu
    assert_args_contain BWRAP_ARGS --ro-bind-try /sys/devices/system/node /sys/devices/system/node
    assert_args_contain BWRAP_ARGS --ro-bind-try /sys/kernel/mm/transparent_hugepage /sys/kernel/mm/transparent_hugepage
    refute_args_contain BWRAP_ARGS --ro-bind /sys /sys
}

@test "the script's own cgroup is mounted at /sys/fs/cgroup" {
    printf '0::/user.slice/user-1000.slice/app.slice/app-x.scope\n' > "$PROC_SELF_CGROUP"
    mount_minimal_sys
    assert_args_contain BWRAP_ARGS --ro-bind-try "$CGROUP_V2_ROOT/user.slice/user-1000.slice/app.slice/app-x.scope" /sys/fs/cgroup
}

@test "in the root cgroup (or a cgroup namespace) the cgroup root itself is mounted" {
    printf '0::/\n' > "$PROC_SELF_CGROUP"
    mount_minimal_sys
    assert_args_contain BWRAP_ARGS --ro-bind-try "$CGROUP_V2_ROOT" /sys/fs/cgroup
}

@test "cgroup v1 and hybrid hosts get no cgroup mount" {
    rm "$CGROUP_V2_ROOT/cgroup.controllers"
    printf '12:memory:/user.slice\n0::/user.slice\n' > "$PROC_SELF_CGROUP"
    mount_minimal_sys
    refute_args_contain BWRAP_ARGS /sys/fs/cgroup
    run own_cgroup_path
    assert_output ""
}

@test "own_cgroup_path picks the unified line among v1 controllers" {
    printf '1:name=systemd:/x\n0::/user.slice/a.scope\n' > "$PROC_SELF_CGROUP"
    run own_cgroup_path
    assert_output /user.slice/a.scope
}
