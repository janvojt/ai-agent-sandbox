#!/usr/bin/env bats
# Git worktree support: resolve_git_worktree may only follow a .git link whose
# target has the layout git writes for a worktree of this very working tree,
# because the .git file is writable by the agent. mount_git_linked_dirs then
# binds the verified common dir. Every forged link must bind nothing and leave
# a warning. Real repositories are created with git under BATS_TEST_TMPDIR.

setup() {
    load ../test_helper/common
    setup_test_env
    REPOS="$BATS_TEST_TMPDIR/repos"
    mkdir -p "$REPOS"
    REPOS="$(cd "$REPOS" && pwd -P)"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null
}

# Usage: make_repo <dir>; a repository with one commit
make_repo() {
    git init -q "$1"
    git -C "$1" config user.name "Test User"
    git -C "$1" config user.email "test@example.com"
    git -C "$1" commit -q --allow-empty -m initial
}

# Usage: make_worktree <repo> <dir> [git worktree add options...]
make_worktree() {
    local repo="$1" dir="$2"
    shift 2
    git -C "$repo" worktree add -q "$@" "$dir" >/dev/null 2>&1
}

# Source the script with the given directory as working directory, so that
# WORKING_DIR and the PROJECT_CONFIG_* paths derive from it, then resolve the
# worktree and mount the linked directories into a fresh BWRAP_ARGS.
resolve_in() {
    cd "$1"
    load_sandbox_script
    QUIET=true
    BWRAP_ARGS=()
    resolve_git_worktree
    mount_git_linked_dirs
}

# Assert that nothing was bound and a warning containing $1 was recorded
assert_not_followed() {
    assert_equal "$GIT_WORKTREE_COMMON_DIR" ""
    assert_equal "${#GIT_LINKED_DIRS[@]}" 0
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_equal "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" ""
    [[ ${#GIT_WORKTREE_WARNINGS[@]} -gt 0 ]] || fail "no warning recorded"
    run printf '%s\n' "${GIT_WORKTREE_WARNINGS[@]}"
    assert_output --partial "$1"
}

# --- resolve_git_link_path -------------------------------------------------------

@test "resolve_git_link_path resolves relative paths against the base directory" {
    load_sandbox_script
    run resolve_git_link_path /a/b ../c/./d
    assert_output /a/c/d
}

@test "resolve_git_link_path keeps absolute paths and normalises them" {
    load_sandbox_script
    run resolve_git_link_path /ignored /x/y/../z
    assert_output /x/z
}

@test "resolve_git_link_path resolves symlinks in the path" {
    load_sandbox_script
    mkdir -p "$REPOS/real"
    ln -s "$REPOS/real" "$REPOS/link"
    run resolve_git_link_path "$REPOS" link/sub
    assert_output "$REPOS/real/sub"
}

# --- Verified worktrees ------------------------------------------------------------

@test "a git worktree binds the main repository's .git read-write" {
    make_repo "$REPOS/main"
    make_worktree "$REPOS/main" "$REPOS/wt"
    resolve_in "$REPOS/wt"
    assert_equal "$GIT_WORKTREE_COMMON_DIR" "$REPOS/main/.git"
    assert_args_contain BWRAP_ARGS --bind "$REPOS/main/.git" "$REPOS/main/.git"
    assert_equal "${GIT_LINKED_DIRS[*]}" "$REPOS/main/.git"
    assert_equal "${#GIT_WORKTREE_WARNINGS[@]}" 0
}

@test "a worktree created with relative paths is followed as well" {
    make_repo "$REPOS/main"
    git -C "$REPOS/main" -c worktree.useRelativePaths=true worktree add -q "$REPOS/wt" >/dev/null 2>&1 \
        || skip "git $(git --version) does not support worktree.useRelativePaths"
    grep -q '^gitdir: \.\.' "$REPOS/wt/.git" || skip "git wrote an absolute gitdir link"
    resolve_in "$REPOS/wt"
    assert_equal "$GIT_WORKTREE_COMMON_DIR" "$REPOS/main/.git"
    assert_args_contain BWRAP_ARGS --bind "$REPOS/main/.git" "$REPOS/main/.git"
    assert_equal "${#GIT_WORKTREE_WARNINGS[@]}" 0
}

@test "the mount is logged unless quiet" {
    make_repo "$REPOS/main"
    make_worktree "$REPOS/main" "$REPOS/wt"
    cd "$REPOS/wt"
    load_sandbox_script
    BWRAP_ARGS=()
    resolve_git_worktree
    run mount_git_linked_dirs
    assert_output --partial "Mounted linked git directory read-write: $REPOS/main/.git"
}

@test "a normal checkout binds nothing and warns nothing" {
    make_repo "$REPOS/main"
    resolve_in "$REPOS/main"
    assert_equal "$GIT_WORKTREE_COMMON_DIR" ""
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_equal "${#GIT_LINKED_DIRS[@]}" 0
    assert_equal "${#GIT_WORKTREE_WARNINGS[@]}" 0
}

@test "a directory without .git binds nothing and warns nothing" {
    resolve_in "$TEST_WORK"
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_equal "${#GIT_WORKTREE_WARNINGS[@]}" 0
}

@test "a common dir inside the working directory is not bound again" {
    # Hand-built layout: the working directory contains its own common dir
    make_repo "$REPOS/main"
    local work="$REPOS/self"
    mkdir -p "$work/c/worktrees/x" "$work/c/objects"
    touch "$work/c/HEAD"
    echo "$work/.git" > "$work/c/worktrees/x/gitdir"
    echo "../.." > "$work/c/worktrees/x/commondir"
    echo "gitdir: c/worktrees/x" > "$work/.git"
    resolve_in "$work"
    assert_equal "$GIT_WORKTREE_COMMON_DIR" "$work/c"
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_equal "${#GIT_LINKED_DIRS[@]}" 0
}

@test "a working directory inside its own common dir binds nothing" {
    # The working directory is <common>/worktrees, the gitdir a subdirectory of it
    local common="$REPOS/c"
    mkdir -p "$common/worktrees/x" "$common/objects"
    touch "$common/HEAD"
    echo "$common/worktrees/.git" > "$common/worktrees/x/gitdir"
    echo "../.." > "$common/worktrees/x/commondir"
    echo "gitdir: x" > "$common/worktrees/.git"
    resolve_in "$common/worktrees"
    assert_equal "$GIT_WORKTREE_COMMON_DIR" "$common"
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_equal "${#GIT_LINKED_DIRS[@]}" 0
}

# --- Forged or unsupported links ---------------------------------------------------

@test "a .git file that is not a gitdir link is only reported" {
    echo "garbage" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "is not a gitdir link"
}

@test "a gitdir that does not exist is not followed" {
    echo "gitdir: $REPOS/missing" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "does not exist"
}

@test ".git rewritten to an arbitrary host directory is not followed" {
    mkdir -p "$REPOS/secret"
    echo "gitdir: $REPOS/secret" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "is not a git worktree directory"
    refute_args_contain BWRAP_ARGS "$REPOS/secret"
}

@test ".git rewritten to a host repository's .git is not followed" {
    make_repo "$REPOS/other"
    echo "gitdir: $REPOS/other/.git" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "is not a git worktree directory"
}

@test "a forged link through a symlink inside the working directory is not followed" {
    mkdir -p "$REPOS/secret"
    ln -s "$REPOS/secret" "$TEST_WORK/innocent"
    echo "gitdir: innocent" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "is not a git worktree directory"
}

@test "a symlink named worktrees inside the working directory does not fake the layout" {
    # <work>/fake/worktrees -> a host directory; realpath resolves the link,
    # so the derived common dir is not <work>/fake
    make_repo "$REPOS/main"
    mkdir -p "$TEST_WORK/fake" "$REPOS/host/x"
    ln -s "$REPOS/host" "$TEST_WORK/fake/worktrees"
    echo "gitdir: fake/worktrees/x" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "is not a git worktree directory"
}

@test "a worktree whose commondir file was rewritten is not followed" {
    make_repo "$REPOS/main"
    make_repo "$REPOS/other"
    make_worktree "$REPOS/main" "$REPOS/wt"
    echo "$REPOS/other/.git" > "$REPOS/main/.git/worktrees/wt/commondir"
    resolve_in "$REPOS/wt"
    assert_not_followed "commondir does not point at $REPOS/main/.git"
    refute_args_contain BWRAP_ARGS "$REPOS/other/.git"
}

@test "a worktree without a commondir file is not followed" {
    make_repo "$REPOS/main"
    make_worktree "$REPOS/main" "$REPOS/wt"
    rm "$REPOS/main/.git/worktrees/wt/commondir"
    resolve_in "$REPOS/wt"
    assert_not_followed "commondir is missing"
}

@test "a worktree without a gitdir back-link is not followed" {
    make_repo "$REPOS/main"
    make_worktree "$REPOS/main" "$REPOS/wt"
    rm "$REPOS/main/.git/worktrees/wt/gitdir"
    resolve_in "$REPOS/wt"
    assert_not_followed "gitdir is missing"
}

@test ".git pointing at another repository's worktree gitdir is not followed" {
    make_repo "$REPOS/other"
    make_worktree "$REPOS/other" "$REPOS/other-wt"
    echo "gitdir: $REPOS/other/.git/worktrees/other-wt" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "belongs to the worktree $REPOS/other-wt/.git"
    refute_args_contain BWRAP_ARGS "$REPOS/other/.git"
}

@test ".git pointing at this repository's worktree gitdir from a different directory is not followed" {
    make_repo "$REPOS/main"
    make_worktree "$REPOS/main" "$REPOS/wt"
    cp "$REPOS/wt/.git" "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "belongs to the worktree $REPOS/wt/.git, not to $TEST_WORK/.git"
}

@test "a common dir without HEAD and objects is not followed" {
    local common="$REPOS/notgit"
    mkdir -p "$common/worktrees/x"
    echo "$TEST_WORK/.git" > "$common/worktrees/x/gitdir"
    echo "../.." > "$common/worktrees/x/commondir"
    echo "gitdir: $common/worktrees/x" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_not_followed "$common is not a git directory"
}

@test "a --separate-git-dir checkout is not followed and the warning names the workaround" {
    make_repo "$REPOS/src"
    git clone -q --separate-git-dir="$REPOS/sep.git" "$REPOS/src" "$REPOS/clone" 2>/dev/null
    resolve_in "$REPOS/clone"
    assert_not_followed "is not a git worktree directory"
    run printf '%s\n' "${GIT_WORKTREE_WARNINGS[@]}"
    assert_output --partial "--whitelist-path-rw"
    refute_args_contain BWRAP_ARGS "$REPOS/sep.git"
}

@test "warnings are logged by mount_git_linked_dirs" {
    mkdir -p "$REPOS/secret"
    echo "gitdir: $REPOS/secret" > "$TEST_WORK/.git"
    load_sandbox_script
    BWRAP_ARGS=()
    resolve_git_worktree
    run mount_git_linked_dirs
    assert_output --partial "not following the .git link"
}

# --- The main checkout's config.local.yaml ------------------------------------------

@test "a worktree loads the main checkout's config.local.yaml when it has none" {
    make_repo "$REPOS/main"
    mkdir -p "$REPOS/main/.ai-agent-sandbox"
    echo "profile: work" > "$REPOS/main/.ai-agent-sandbox/config.local.yaml"
    make_worktree "$REPOS/main" "$REPOS/wt"
    resolve_in "$REPOS/wt"
    assert_equal "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" "$REPOS/main/.ai-agent-sandbox/config.local.yaml"
    run is_project_config_file "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE"
    assert_success
}

@test "the main checkout's profile is loaded and counts as a project profile" {
    make_repo "$REPOS/main"
    mkdir -p "$REPOS/main/.ai-agent-sandbox"
    echo "profile: work" > "$REPOS/main/.ai-agent-sandbox/config.local.yaml"
    make_worktree "$REPOS/main" "$REPOS/wt"
    resolve_in "$REPOS/wt"
    load_config_files
    assert_equal "$PROFILE" work
    assert_equal "$PROJECT_PROFILE" work
    assert_equal "$PROJECT_PROFILE_SOURCE" "$REPOS/main/.ai-agent-sandbox/config.local.yaml"
}

@test "a worktree's own config.local.yaml replaces the main checkout's" {
    make_repo "$REPOS/main"
    mkdir -p "$REPOS/main/.ai-agent-sandbox"
    echo "profile: work" > "$REPOS/main/.ai-agent-sandbox/config.local.yaml"
    make_worktree "$REPOS/main" "$REPOS/wt"
    mkdir -p "$REPOS/wt/.ai-agent-sandbox"
    echo "profile: private" > "$REPOS/wt/.ai-agent-sandbox/config.local.yaml"
    resolve_in "$REPOS/wt"
    assert_equal "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" ""
    load_config_files
    assert_equal "$PROFILE" private
}

@test "the main checkout itself does not reference its own config.local.yaml" {
    make_repo "$REPOS/main"
    mkdir -p "$REPOS/main/.ai-agent-sandbox"
    echo "profile: work" > "$REPOS/main/.ai-agent-sandbox/config.local.yaml"
    resolve_in "$REPOS/main"
    assert_equal "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" ""
}

@test "a forged .git does not load another checkout's config.local.yaml" {
    make_repo "$REPOS/main"
    mkdir -p "$REPOS/main/.ai-agent-sandbox"
    echo "profile: work" > "$REPOS/main/.ai-agent-sandbox/config.local.yaml"
    echo "gitdir: $REPOS/main/.git" > "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_equal "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" ""
}

@test "a forged link to another checkout's worktree does not load its config.local.yaml" {
    make_repo "$REPOS/main"
    mkdir -p "$REPOS/main/.ai-agent-sandbox"
    echo "profile: work" > "$REPOS/main/.ai-agent-sandbox/config.local.yaml"
    make_worktree "$REPOS/main" "$REPOS/wt"
    cp "$REPOS/wt/.git" "$TEST_WORK/.git"
    resolve_in "$TEST_WORK"
    assert_equal "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" ""
}

@test "a bare repository's worktree does not look for a main checkout" {
    make_repo "$REPOS/src"
    git clone -q --bare "$REPOS/src" "$REPOS/bare.git"
    make_worktree "$REPOS/bare.git" "$REPOS/wt"
    mkdir -p "$REPOS/.ai-agent-sandbox"
    echo "profile: work" > "$REPOS/.ai-agent-sandbox/config.local.yaml"
    resolve_in "$REPOS/wt"
    assert_equal "$GIT_WORKTREE_COMMON_DIR" "$REPOS/bare.git"
    assert_equal "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" ""
}
