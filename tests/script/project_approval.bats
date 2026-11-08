#!/usr/bin/env bats
# Script-level tests of the opt-in approval of project config files
# (require_project_approval, --approve-project-config).

setup() {
    load ../test_helper/common
    setup_test_env
    USER_CONFIG="$TEST_HOME/.config/ai-agent-sandbox/config.yaml"
    PROJECT_DIR="$TEST_WORK/.ai-agent-sandbox"
    APPROVALS="$TEST_HOME/.local/state/ai-agent-sandbox/approved-config"
    mkdir -p "$(dirname "$USER_CONFIG")" "$PROJECT_DIR"
    printf 'whitelist:\n  - /usr/bin\nrequire_project_approval: true\n' > "$USER_CONFIG"
    printf 'whitelist:\n  - /opt\n' > "$PROJECT_DIR/config.yaml"
}

@test "off by default: an unapproved project file applies" {
    printf 'whitelist:\n  - /usr/bin\n' > "$USER_CONFIG"
    run_sandbox --dry-run
    assert_success
    refute_output --partial "Project Config Approval"
}

@test "an unapproved project file refuses the start without a terminal" {
    run_sandbox --dry-run
    assert_failure 1
    assert_output --partial "project configuration not approved"
    assert_output --partial "$PROJECT_DIR/config.yaml"
    assert_output --partial "--approve-project-config"
    assert_file_not_exists "$BWRAP_ARGS_FILE"
}

@test "--approve-project-config shows the file, records it and exits; the next start runs" {
    run_sandbox --approve-project-config
    assert_success
    assert_output --partial "Not approved yet: $PROJECT_DIR/config.yaml"
    assert_output --partial "  - /opt"
    assert_file_not_exists "$BWRAP_ARGS_FILE"
    run stat -c %a "$APPROVALS"
    assert_output 700

    run_sandbox --dry-run
    assert_success
    assert_output --partial "Project Config Approval: required (1 project file approved)"

    run_sandbox --approve-project-config
    assert_success
    assert_output --partial "nothing to do"
}

@test "a changed file is refused again and shown as a diff; an earlier approved version passes" {
    run_sandbox --approve-project-config
    assert_success
    printf 'whitelist:\n  - /opt\n  - ~/.ssh\n' > "$PROJECT_DIR/config.yaml"
    run_sandbox --dry-run
    assert_failure 1
    run_sandbox --approve-project-config
    assert_success
    assert_output --partial "Changed since approved: $PROJECT_DIR/config.yaml"
    assert_line "+  - ~/.ssh"
    printf 'whitelist:\n  - /opt\n' > "$PROJECT_DIR/config.yaml"
    run_sandbox --dry-run
    assert_success
}

@test "escape sequences in a project file are shown escaped" {
    printf 'whitelist:\n  - /opt # \033[2K\n' > "$PROJECT_DIR/config.yaml"
    run env bash "$SANDBOX_SCRIPT" --approve-project-config </dev/null
    assert_success
    assert_output --partial '^[[2K'
}

@test "every project file needs approval" {
    printf 'quiet: false\n' > "$PROJECT_DIR/config.local.yaml"
    run_sandbox --approve-project-config
    assert_success
    assert_output --partial "Approved 2 project files"
}

@test "no project files: nothing to approve" {
    rm "$PROJECT_DIR/config.yaml"
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Project Config Approval: required (0 project files approved)"
}

@test "the setting is ignored in a project file and --no-require-project-approval beats the user config" {
    run_sandbox --dry-run --no-require-project-approval
    assert_success
    printf 'whitelist:\n  - /usr/bin\n' > "$USER_CONFIG"
    printf 'require_project_approval: false\n' >> "$PROJECT_DIR/config.yaml"
    run_sandbox --dry-run --require-project-approval
    assert_failure 1
    run_sandbox --dry-run
    assert_success
    printf 'require_project_approval: true\n' > "$PROJECT_DIR/config.yaml"
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Ignoring 'require_project_approval'"
}

@test "the approvals are hidden when a whitelist entry covers them" {
    run_sandbox --approve-project-config
    assert_success
    run_sandbox --dry-run --whitelist-path-rw "$TEST_HOME/.local/state"
    assert_success
    assert_args_contain BWRAP_RECORDED --tmpfs "$APPROVALS"
}

@test "a git worktree shares the approvals of its main checkout" {
    command -v git >/dev/null || skip "git is not installed"
    git -C "$TEST_WORK" init -q
    git -C "$TEST_WORK" add .ai-agent-sandbox/config.yaml
    git -C "$TEST_WORK" -c user.name=t -c user.email=t@t commit -qm init
    run_sandbox --approve-project-config
    assert_success
    local wt="$BATS_TEST_TMPDIR/wt"
    git -C "$TEST_WORK" worktree add -q "$wt"
    cd "$wt"
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Project Config Approval: required (1 project file approved)"
}

@test "in a terminal, the start asks and continues after yes" {
    command -v script >/dev/null || skip "script (util-linux) is not installed"
    stub_bwrap
    stub_command claude 'echo "2.1.0 (Claude Code)"'
    run bash -c "printf 'n\n' | script -qec 'AI_AGENT_SANDBOX_NETWORK=host bash $SANDBOX_SCRIPT --dry-run' /dev/null"
    assert_output --partial "Approve and use this configuration?"
    assert_output --partial "Not approved."
    assert_file_not_exists "$BWRAP_ARGS_FILE"
    run bash -c "printf 'y\n' | script -qec 'AI_AGENT_SANDBOX_NETWORK=host bash $SANDBOX_SCRIPT --dry-run' /dev/null"
    output="$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')"
    assert_output --partial "Approved 1 project file"
    assert_output --partial "Project Config Approval: required (1 project file approved, 1 just now)"
    assert_file_exists "$BWRAP_ARGS_FILE"
}

# Usage: stub_dialog <name> <exit-status>
# A dialog program that records its arguments and the text file it was given
stub_dialog() {
    stub_command "$1" "printf '%s\n' \"\$@\" >> '$BATS_TEST_TMPDIR/$1.args'
for ((i = 1; i <= \$#; i++)); do
    if [[ \"\${!i}\" == --filename || \"\${!i}\" == --textbox ]]; then
        j=\$((i + 1)); cat \"\${!j}\" >> '$BATS_TEST_TMPDIR/$1.text'
    fi
done
exit $2"
}

@test "without a terminal, a desktop dialog asks and Approve starts the sandbox" {
    stub_dialog zenity 0
    RUN_SANDBOX_ENV_OPTIONS=(DISPLAY=:99)
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Project Config Approval: required (1 project file approved, 1 just now)"
    assert_file_exists "$BWRAP_ARGS_FILE"
    run cat "$BATS_TEST_TMPDIR/zenity.text"
    assert_output --partial "Not approved yet: $PROJECT_DIR/config.yaml"
    assert_output --partial "  - /opt"
    assert_output --partial "--approve-project-config"
    run cat "$BATS_TEST_TMPDIR/zenity.args"
    assert_line --text-info
    assert_line Approve

    # Approved now: no second dialog
    rm "$BATS_TEST_TMPDIR/zenity.args"
    run_sandbox --dry-run
    assert_success
    assert_file_not_exists "$BATS_TEST_TMPDIR/zenity.args"
}

@test "Deny in the desktop dialog refuses the start without a notification" {
    stub_dialog zenity 1
    stub_command notify-send "touch '$BATS_TEST_TMPDIR/notified'"
    RUN_SANDBOX_ENV_OPTIONS=(DISPLAY=:99 DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent)
    run_sandbox --dry-run
    assert_failure 1
    assert_output --partial "denied in the desktop dialog"
    assert_file_not_exists "$BWRAP_ARGS_FILE"
    assert_file_not_exists "$BATS_TEST_TMPDIR/notified"
    run_sandbox --dry-run
    assert_failure 1
}

@test "a dialog without an answer refuses the start and notifies" {
    stub_dialog zenity 5
    stub_command notify-send "printf '%s\n' \"\$@\" > '$BATS_TEST_TMPDIR/notify.args'"
    RUN_SANDBOX_ENV_OPTIONS=(DISPLAY=:99 DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent)
    run_sandbox --dry-run
    assert_failure 1
    assert_output --partial "No answer in the desktop approval dialog"
    run cat "$BATS_TEST_TMPDIR/notify.args"
    assert_line "Sandbox refused to start: project configuration not approved"
    assert_output --partial "$PROJECT_DIR/config.yaml"
}

@test "--no-desktop-prompts and desktop_prompts: false refuse without a dialog or notification" {
    stub_dialog zenity 0
    stub_command notify-send "touch '$BATS_TEST_TMPDIR/notified'"
    RUN_SANDBOX_ENV_OPTIONS=(DISPLAY=:99 DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent)
    run_sandbox --dry-run --no-desktop-prompts
    assert_failure 1
    assert_file_not_exists "$BATS_TEST_TMPDIR/zenity.args"
    assert_file_not_exists "$BATS_TEST_TMPDIR/notified"
    printf 'desktop_prompts: false\n' >> "$USER_CONFIG"
    run_sandbox --dry-run
    assert_failure 1
    assert_file_not_exists "$BATS_TEST_TMPDIR/zenity.args"
    run_sandbox --dry-run --desktop-prompts
    assert_success
    assert_file_exists "$BATS_TEST_TMPDIR/zenity.args"
}

@test "desktop_prompts in a project file is ignored" {
    stub_dialog zenity 0
    printf 'desktop_prompts: false\n' >> "$PROJECT_DIR/config.yaml"
    RUN_SANDBOX_ENV_OPTIONS=(DISPLAY=:99)
    run_sandbox --dry-run
    assert_success
    assert_output --partial "Ignoring 'desktop_prompts'"
    assert_file_exists "$BATS_TEST_TMPDIR/zenity.args"
}

@test "a refused start is logged for orchestrators that discard stderr" {
    run_sandbox --dry-run
    assert_failure 1
    local log="$TEST_HOME/.local/state/ai-agent-sandbox/refusals.log"
    assert_file_exists "$log"
    run cat "$log"
    assert_output --partial " $TEST_WORK"
    assert_output --partial "  project configuration not approved:"
    assert_output --partial "    $PROJECT_DIR/config.yaml"
}
