#!/usr/bin/env bats
# Terminal session: when the sandbox is detached from the terminal with
# bwrap --new-session (blocks TIOCSTI input injection) and when it is not.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    LEGACY_TIOCSTI_SYSCTL="$BATS_TEST_TMPDIR/legacy_tiocsti"
}

# Usage: with_terminal <true|false>; overrides the stdio check
with_terminal() {
    if [[ "$1" = true ]]; then
        stdio_is_terminal() { return 0; }
    else
        stdio_is_terminal() { return 1; }
    fi
}

@test "without a terminal the sandbox always gets a new session" {
    with_terminal false
    SECCOMP_LEVEL=strict
    resolve_new_session
    assert_equal "$NEW_SESSION" true
    assert_equal "$NEW_SESSION_REASON" "no terminal attached"
}

@test "in a terminal the session is shared while the syscall filter blocks TIOCSTI" {
    with_terminal true
    echo 1 > "$LEGACY_TIOCSTI_SYSCTL"
    SECCOMP_LEVEL=default
    resolve_new_session
    assert_equal "$NEW_SESSION" false
    assert_equal "$NEW_SESSION_REASON" "TIOCSTI is blocked by the syscall filter"
}

@test "in a terminal without the filter the kernel setting decides" {
    with_terminal true
    SECCOMP_LEVEL=off
    echo 0 > "$LEGACY_TIOCSTI_SYSCTL"
    resolve_new_session
    assert_equal "$NEW_SESSION" false
    assert_equal "$NEW_SESSION_REASON" "TIOCSTI is blocked by the kernel"

    NEW_SESSION=auto
    echo 1 > "$LEGACY_TIOCSTI_SYSCTL"
    resolve_new_session
    assert_equal "$NEW_SESSION" true
    assert_equal "$NEW_SESSION_REASON" "TIOCSTI is not blocked otherwise"
}

@test "a kernel without the legacy_tiocsti setting allows TIOCSTI" {
    with_terminal true
    SECCOMP_LEVEL=off
    rm -f "$LEGACY_TIOCSTI_SYSCTL"
    resolve_new_session
    assert_equal "$NEW_SESSION" true
}

@test "--new-session and --no-new-session override the automatic choice" {
    with_terminal true
    SECCOMP_LEVEL=strict NEW_SESSION=true
    resolve_new_session
    assert_equal "$NEW_SESSION" true
    assert_equal "$NEW_SESSION_REASON" "--new-session"

    with_terminal false
    NEW_SESSION=false
    resolve_new_session
    assert_equal "$NEW_SESSION" false
    assert_equal "$NEW_SESSION_REASON" "--no-new-session"
}
