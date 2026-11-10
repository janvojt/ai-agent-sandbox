#!/usr/bin/env bats
# Desktop prompts for starts without a terminal: approval dialogs (zenity,
# kdialog), notifications about refused starts and the refusal log.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    TEXT="$BATS_TEST_TMPDIR/text"
    printf 'some text\n' > "$TEXT"
}

# Usage: stub_recording <name> <exit-status>
stub_recording() {
    stub_command "$1" "printf '%s\n' \"\$@\" >> '$BATS_TEST_TMPDIR/$1.args'; exit $2"
}

# --- desktop_dialog_tool --------------------------------------------------------

@test "no dialog without a graphical session or with desktop prompts off" {
    stub_recording zenity 0
    run desktop_dialog_tool
    assert_failure
    DISPLAY=:99 DESKTOP_PROMPTS=false run desktop_dialog_tool
    assert_failure
    WAYLAND_DISPLAY=wayland-0 run desktop_dialog_tool
    assert_success
    assert_output zenity
}

# --- desktop_approval_dialog ----------------------------------------------------

@test "zenity: Approve, Deny and its timeout" {
    stub_recording zenity 0
    run desktop_approval_dialog zenity "Title" "$TEXT"
    assert_success
    run cat "$BATS_TEST_TMPDIR/zenity.args"
    assert_line --text-info
    assert_line "$TEXT"
    assert_line Approve
    stub_recording zenity 1
    run desktop_approval_dialog zenity "Title" "$TEXT"
    assert_failure 1
    stub_recording zenity 5
    run desktop_approval_dialog zenity "Title" "$TEXT"
    assert_failure 2
}

@test "kdialog: the text first, then the question" {
    stub_recording kdialog 0
    run desktop_approval_dialog kdialog "Title" "$TEXT"
    assert_success
    run cat "$BATS_TEST_TMPDIR/kdialog.args"
    assert_line --textbox
    assert_line "$TEXT"
    assert_line --warningyesno
    stub_recording kdialog 1
    run desktop_approval_dialog kdialog "Title" "$TEXT"
    assert_failure 1
}

@test "a dialog that cannot be shown counts as no answer" {
    stub_recording zenity 255
    run desktop_approval_dialog zenity "Title" "$TEXT"
    assert_failure 2
}

# --- notify_desktop / refuse_start ------------------------------------------------

@test "notifications need a session bus and escape markup" {
    stub_recording notify-send 0
    notify_desktop "Summary" "a <b>bold</b> & more"
    assert_file_not_exists "$BATS_TEST_TMPDIR/notify-send.args"
    DBUS_SESSION_BUS_ADDRESS=unix:path=/x notify_desktop "Summary" "a <b>bold</b> & more"
    run cat "$BATS_TEST_TMPDIR/notify-send.args"
    assert_line Summary
    assert_line "a &lt;b&gt;bold&lt;/b&gt; &amp; more"
}

@test "refuse_start prints, logs and notifies, then exits 1" {
    stub_recording notify-send 0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/x
    REFUSAL_LOG_FILE="$BATS_TEST_TMPDIR/state/refusals.log"
    run refuse_start "Summary" "something is wrong" "do this"
    assert_failure 1
    assert_output --partial "Error: something is wrong"
    assert_output --partial "do this"
    run cat "$REFUSAL_LOG_FILE"
    assert_line "  something is wrong"
    assert_line "  do this"
    run cat "$BATS_TEST_TMPDIR/notify-send.args"
    assert_line Summary
    assert_output --partial "logged in $REFUSAL_LOG_FILE"
}

@test "the refusal log is trimmed" {
    REFUSAL_LOG_FILE="$BATS_TEST_TMPDIR/refusals.log"
    seq 2001 > "$REFUSAL_LOG_FILE"
    log_refusal "last"
    run wc -l < "$REFUSAL_LOG_FILE"
    assert_output 1000
    run tail -n 1 "$REFUSAL_LOG_FILE"
    assert_output "  last"
}

@test "a profile mismatch is a refused start" {
    REFUSAL_LOG_FILE="$BATS_TEST_TMPDIR/refusals.log"
    PROJECT_PROFILE=work
    PROJECT_PROFILE_SOURCE=project
    PROFILE=private
    PROFILE_SOURCE=AI_AGENT_SANDBOX_PROFILE
    run check_project_profile
    assert_failure 1
    run cat "$REFUSAL_LOG_FILE"
    assert_output --partial "profile mismatch"
}
