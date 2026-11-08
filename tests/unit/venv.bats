#!/usr/bin/env bats
# Virtual environments: --venv[=SOURCE] / the venv key pick the active
# $VIRTUAL_ENV, the project's pipenv environment (asked on the host) or a path.
# In a git worktree the pipenv environment and relative paths fall back to the
# main checkout, because venvs are git-ignored and pipenv names its
# environments after the project path.

setup() {
    load ../test_helper/common
    setup_test_env
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null
    unset VIRTUAL_ENV PIPENV_ACTIVE PIPENV_PIPFILE
    PIPENV_LOG="$BATS_TEST_TMPDIR/pipenv.log"
}

# Usage: make_venv <dir>; a minimal virtual environment
make_venv() {
    mkdir -p "$1/bin"
    touch "$1/pyvenv.cfg"
    ln -sf /usr/bin/python3 "$1/bin/python"
}

# Stub pipenv that logs its Pipfile and working directory and prints the venv
# registered for that Pipfile in the file "<Pipfile dir>/.stub-venv"
stub_pipenv() {
    stub_command pipenv "echo \"\$PIPENV_PIPFILE \$PWD \$PIPENV_DONT_LOAD_ENV \$PIPENV_IGNORE_VIRTUALENVS \${VIRTUAL_ENV:-none}\" >> '$PIPENV_LOG'
[[ \"\$1\" == --venv ]] || exit 2
dir=\$(dirname \"\$PIPENV_PIPFILE\")
[[ -f \"\$dir/.stub-venv\" ]] || { echo 'No virtualenv has been created' >&2; exit 1; }
echo 'Courtesy notice'
cat \"\$dir/.stub-venv\""
}

detect_in() {
    cd "$1"
    load_sandbox_script
    QUIET=false
    resolve_git_worktree
    shift
    apply_venv_setting "$1"
    detect_venv
}

# --- apply_venv_setting -------------------------------------------------------------

@test "apply_venv_setting accepts booleans, active, pipenv and paths" {
    load_sandbox_script
    apply_venv_setting yes
    assert_equal "$ENABLE_VENV $VENV_SOURCE" "true active"
    apply_venv_setting pipenv
    assert_equal "$ENABLE_VENV $VENV_SOURCE" "true pipenv"
    apply_venv_setting off
    assert_equal "$ENABLE_VENV" false
    for value in .venv ./env /opt/venv '~/venvs/x' '$HOME/venvs/x' venvs/x; do
        apply_venv_setting "$value"
        assert_equal "$ENABLE_VENV $VENV_SOURCE" "true $value"
    done
}

@test "apply_venv_setting refuses a misspelt keyword" {
    load_sandbox_script
    run apply_venv_setting pipnev
    assert_failure
    run apply_venv_setting ture
    assert_failure
}

@test "the venv key accepts pipenv and paths and refuses unknown words" {
    load_sandbox_script
    apply_config_scalar venv pipenv f.yaml false
    assert_equal "$ENABLE_VENV $VENV_SOURCE" "true pipenv"
    apply_config_scalar venv .venv f.yaml false
    assert_equal "$VENV_SOURCE" .venv
    run apply_config_scalar venv ture f.yaml false
    assert_failure
    assert_output --partial "Invalid value for 'venv'"
}

# --- Sources --------------------------------------------------------------------------

@test "active uses \$VIRTUAL_ENV" {
    make_venv "$TEST_WORK/.venv"
    export VIRTUAL_ENV="$TEST_WORK/.venv"
    detect_in "$TEST_WORK" true
    assert_equal "$ENABLE_VENV" true
    assert_equal "$VENV_PATH" "$TEST_WORK/.venv"
    assert_equal "$VENV_BIN_DIR" "$TEST_WORK/.venv/bin"
}

@test "active without \$VIRTUAL_ENV disables the venv and suggests pipenv" {
    run detect_in "$TEST_WORK" true
    assert_output --partial "no active virtual environment"
    assert_output --partial "--venv=pipenv"
    detect_in "$TEST_WORK" true >/dev/null
    assert_equal "$ENABLE_VENV" false
}

@test "a relative path is resolved in the working directory" {
    make_venv "$TEST_WORK/.venv"
    detect_in "$TEST_WORK" .venv
    assert_equal "$ENABLE_VENV" true
    assert_equal "$VENV_PATH" "$TEST_WORK/.venv"
}

@test "a directory that is not a venv is not mounted" {
    mkdir -p "$TEST_HOME/bin"
    run detect_in "$TEST_WORK" '~'
    assert_output --partial "is not a Python virtual environment"
    detect_in "$TEST_WORK" '~' >/dev/null
    assert_equal "$ENABLE_VENV" false
    assert_equal "$VENV_PATH" ""
}

@test "pipenv asks the host's pipenv for the working directory's Pipfile" {
    stub_pipenv
    make_venv "$TEST_HOME/.local/share/virtualenvs/work-abc"
    touch "$TEST_WORK/Pipfile"
    echo "$TEST_HOME/.local/share/virtualenvs/work-abc" > "$TEST_WORK/.stub-venv"
    export VIRTUAL_ENV=/elsewhere
    detect_in "$TEST_WORK" pipenv
    assert_equal "$ENABLE_VENV" true
    assert_equal "$VENV_PATH" "$TEST_HOME/.local/share/virtualenvs/work-abc"
    assert_equal "$VENV_ORIGIN" pipenv
    # Explicit Pipfile, no .env, an activated venv is ignored and not passed
    run cat "$PIPENV_LOG"
    assert_output "$TEST_WORK/Pipfile $TEST_WORK 1 1 none"
}

@test "pipenv without a Pipfile is not run" {
    stub_pipenv
    run detect_in "$TEST_WORK" pipenv
    assert_output --partial "there is no Pipfile"
    assert_file_not_exists "$PIPENV_LOG"
}

@test "pipenv without an environment asks for pipenv install" {
    stub_pipenv
    touch "$TEST_WORK/Pipfile"
    run detect_in "$TEST_WORK" pipenv
    assert_output --partial "run 'pipenv install' on the host"
}

@test "pipenv missing on the host disables the venv" {
    touch "$TEST_WORK/Pipfile"
    # A PATH with only the tools detect_venv needs, so a host pipenv is hidden
    local bin="$BATS_TEST_TMPDIR/minimal-bin" tool
    mkdir -p "$bin"
    for tool in realpath dirname basename; do
        ln -s "$(command -v "$tool")" "$bin/$tool"
    done
    local saved_path="$PATH"
    PATH="$bin"
    run detect_in "$TEST_WORK" pipenv
    PATH="$saved_path"
    assert_output --partial "pipenv is not installed"
}

# --- Git worktrees ---------------------------------------------------------------------

make_checkout_with_worktree() {
    MAIN="$BATS_TEST_TMPDIR/main"
    WT="$BATS_TEST_TMPDIR/wt"
    git init -q "$MAIN"
    git -C "$MAIN" -c user.name=t -c user.email=t@e commit -q --allow-empty -m initial
    git -C "$MAIN" worktree add -q "$WT" >/dev/null 2>&1
    MAIN=$(cd "$MAIN" && pwd -P)
    WT=$(cd "$WT" && pwd -P)
}

@test "pipenv falls back to the main checkout's environment in a worktree" {
    stub_pipenv
    make_checkout_with_worktree
    make_venv "$TEST_HOME/venvs/main-abc"
    touch "$MAIN/Pipfile" "$WT/Pipfile"
    echo "$TEST_HOME/venvs/main-abc" > "$MAIN/.stub-venv"
    detect_in "$WT" pipenv
    assert_equal "$ENABLE_VENV" true
    assert_equal "$VENV_PATH" "$TEST_HOME/venvs/main-abc"
    assert_equal "$VENV_ORIGIN" "pipenv, main checkout $MAIN"
}

@test "the worktree's own pipenv environment wins over the main checkout's" {
    stub_pipenv
    make_checkout_with_worktree
    make_venv "$TEST_HOME/venvs/main-abc"
    make_venv "$TEST_HOME/venvs/wt-def"
    touch "$MAIN/Pipfile" "$WT/Pipfile"
    echo "$TEST_HOME/venvs/main-abc" > "$MAIN/.stub-venv"
    echo "$TEST_HOME/venvs/wt-def" > "$WT/.stub-venv"
    detect_in "$WT" pipenv
    assert_equal "$VENV_PATH" "$TEST_HOME/venvs/wt-def"
}

@test "a relative path missing in a worktree is taken from the main checkout" {
    make_checkout_with_worktree
    make_venv "$MAIN/.venv"
    detect_in "$WT" .venv
    assert_equal "$ENABLE_VENV" true
    assert_equal "$VENV_PATH" "$MAIN/.venv"
}

@test "a forged .git link does not make another directory the main checkout" {
    make_checkout_with_worktree
    make_venv "$MAIN/.venv"
    mkdir -p "$TEST_WORK/fake"
    echo "gitdir: $MAIN/.git" > "$TEST_WORK/.git"
    detect_in "$TEST_WORK" .venv >/dev/null
    assert_equal "$GIT_MAIN_CHECKOUT_DIR" ""
    assert_equal "$ENABLE_VENV" false
}

# --- Interpreter visibility -------------------------------------------------------------

@test "an interpreter outside every mount is reported" {
    make_venv "$TEST_WORK/.venv"
    mkdir -p "$TEST_HOME/.pyenv/bin"
    touch "$TEST_HOME/.pyenv/bin/python3.12"
    ln -sf "$TEST_HOME/.pyenv/bin/python3.12" "$TEST_WORK/.venv/bin/python"
    detect_in "$TEST_WORK" .venv
    BWRAP_ARGS=(--ro-bind /usr /usr)
    run warn_hidden_venv_interpreter
    assert_output --partial "interpreter $TEST_HOME/.pyenv/bin/python3.12 is not visible"
    BWRAP_ARGS=(--ro-bind "$TEST_HOME/.pyenv" "$TEST_HOME/.pyenv")
    run warn_hidden_venv_interpreter
    assert_output ""
}
