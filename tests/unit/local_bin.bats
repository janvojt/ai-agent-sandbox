#!/usr/bin/env bats
# Unit tests of the ~/.local/bin overlay of native Claude installs: the upper
# layer exists for one run only, and only a newer Claude launcher is kept.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    mkdir -p "$HOME/.local/bin"
}

# Usage: install_claude_version <version>; an executable in the version store
install_claude_version() {
    mkdir -p "$CLAUDE_NATIVE_DIR/versions"
    printf '#!/bin/sh\n' > "$CLAUDE_NATIVE_DIR/versions/$1"
    chmod +x "$CLAUDE_NATIVE_DIR/versions/$1"
}

# Usage: host_launcher <version>
host_launcher() {
    install_claude_version "$1"
    ln -sfn "$CLAUDE_NATIVE_DIR/versions/$1" "$CLAUDE_HOST_BIN"
}

# Usage: stored_launcher <version>
stored_launcher() {
    install_claude_version "$1"
    mkdir -p "$CLAUDE_SANDBOX_BIN_DIR"
    ln -sfn "$CLAUDE_NATIVE_DIR/versions/$1" "$CLAUDE_SANDBOX_BIN_DIR/claude"
}

# --- claude_version_newer ------------------------------------------------------

@test "claude_version_newer: compares versions numerically" {
    run claude_version_newer 2.1.10 2.1.9
    assert_success
    run claude_version_newer 2.1.9 2.1.10
    assert_failure
    run claude_version_newer 2.1.9 2.1.9
    assert_failure
    run claude_version_newer 2.1.9 ""
    assert_success
    run claude_version_newer "" 2.1.9
    assert_failure
}

# --- prepare_claude_native_install ---------------------------------------------

@test "prepare_claude_native_install: a stored launcher newer than the host's is kept" {
    host_launcher 2.1.0
    stored_launcher 2.2.0
    prepare_claude_native_install
    assert_equal "$CLAUDE_NATIVE_INSTALL" true
    assert_equal "$(readlink "$CLAUDE_SANDBOX_BIN_DIR/claude")" "$CLAUDE_NATIVE_DIR/versions/2.2.0"
}

@test "prepare_claude_native_install: a stored launcher the host caught up with is removed" {
    host_launcher 2.2.0
    stored_launcher 2.2.0
    prepare_claude_native_install
    assert_not_exists "$CLAUDE_SANDBOX_BIN_DIR/claude"
    assert_equal "$CLAUDE_NATIVE_INSTALL" true
}

# --- prepare_local_bin_run_dir -------------------------------------------------

@test "prepare_local_bin_run_dir: a fresh upper layer per run with the stored launcher" {
    host_launcher 2.1.0
    stored_launcher 2.2.0
    prepare_local_bin_run_dir true
    assert_equal "$(cat "$LOCAL_BIN_RUN_DIR/pid")" "$$"
    assert_dir_exists "$LOCAL_BIN_RUN_DIR/work"
    assert_equal "$(ls -A "$LOCAL_BIN_RUN_DIR/upper")" claude
    assert_equal "$(readlink "$LOCAL_BIN_RUN_DIR/upper/claude")" "$CLAUDE_NATIVE_DIR/versions/2.2.0"
    run stat -c %a "$LOCAL_BIN_RUNS_DIR"
    assert_output 700
}

@test "prepare_local_bin_run_dir: with overlay support the host launcher shows through" {
    host_launcher 2.1.0
    prepare_local_bin_run_dir true
    assert_equal "$(ls -A "$LOCAL_BIN_RUN_DIR/upper")" ""
}

@test "prepare_local_bin_run_dir: without overlay support the upper layer links the host's version" {
    host_launcher 2.1.0
    prepare_local_bin_run_dir false
    assert_equal "$(readlink "$LOCAL_BIN_RUN_DIR/upper/claude")" "$CLAUDE_NATIVE_DIR/versions/2.1.0"
}

@test "prepare_local_bin_run_dir: removes run directories of dead processes only" {
    mkdir -p "$LOCAL_BIN_RUNS_DIR/run.dead/work/work" "$LOCAL_BIN_RUNS_DIR/run.live" "$LOCAL_BIN_RUNS_DIR/run.new"
    chmod 000 "$LOCAL_BIN_RUNS_DIR/run.dead/work/work"
    sleep 0 & local dead=$!
    wait "$dead"
    echo "$dead" > "$LOCAL_BIN_RUNS_DIR/run.dead/pid"
    echo "$PPID" > "$LOCAL_BIN_RUNS_DIR/run.live/pid"
    prepare_local_bin_run_dir true
    assert_not_exists "$LOCAL_BIN_RUNS_DIR/run.dead"
    assert_dir_exists "$LOCAL_BIN_RUNS_DIR/run.live"
    assert_dir_exists "$LOCAL_BIN_RUNS_DIR/run.new"
}

# --- cleanup_local_bin_run_dir -------------------------------------------------

@test "cleanup_local_bin_run_dir: keeps a newer launcher and drops everything else" {
    host_launcher 2.1.0
    prepare_local_bin_run_dir true
    install_claude_version 2.3.0
    # Relative to ~/.local/bin, where the updater sees it
    ln -s ../share/claude/versions/2.3.0 "$LOCAL_BIN_RUN_DIR/upper/claude"
    printf 'x' > "$LOCAL_BIN_RUN_DIR/upper/tool"
    chmod 000 "$LOCAL_BIN_RUN_DIR/work"
    local run_dir="$LOCAL_BIN_RUN_DIR"
    cleanup_local_bin_run_dir
    assert_not_exists "$run_dir"
    assert_equal "$(readlink "$CLAUDE_SANDBOX_BIN_DIR/claude")" "$CLAUDE_NATIVE_DIR/versions/2.3.0"
    assert_equal "$(ls -A "$CLAUDE_SANDBOX_BIN_DIR")" claude
}

@test "cleanup_local_bin_run_dir: an older or foreign launcher is not kept" {
    host_launcher 2.1.0
    stored_launcher 2.2.0
    prepare_local_bin_run_dir true
    install_claude_version 2.1.5
    ln -sfn "$CLAUDE_NATIVE_DIR/versions/2.1.5" "$LOCAL_BIN_RUN_DIR/upper/claude"
    cleanup_local_bin_run_dir
    assert_equal "$(readlink "$CLAUDE_SANDBOX_BIN_DIR/claude")" "$CLAUDE_NATIVE_DIR/versions/2.2.0"

    prepare_local_bin_run_dir true
    printf '#!/bin/sh\n' > "$HOME/evil"
    chmod +x "$HOME/evil"
    ln -sfn "$HOME/evil" "$LOCAL_BIN_RUN_DIR/upper/claude"
    cleanup_local_bin_run_dir
    assert_equal "$(readlink "$CLAUDE_SANDBOX_BIN_DIR/claude")" "$CLAUDE_NATIVE_DIR/versions/2.2.0"
}

@test "cleanup_local_bin_run_dir: no run directory is a no-op" {
    run cleanup_local_bin_run_dir
    assert_success
}
