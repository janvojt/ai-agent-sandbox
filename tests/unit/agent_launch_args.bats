#!/usr/bin/env bats
# Unit tests of the agent command lines: the Claude Code permission flag,
# OpenCode 1's default agent, OpenCode 2's --standalone/--auto insertion
# (build_opencode2_launch_args) and detect_opencode_version.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    AGENT_ARGS=()
    AGENT_LAUNCH_ARGS=()
}

# Usage: assert_opencode2_launch <expected> [agent args...]
# Run build_opencode2_launch_args with the given AGENT_ARGS and compare the
# space-joined AGENT_LAUNCH_ARGS.
assert_opencode2_launch() {
    local expected="$1"
    shift
    AGENT_ARGS=("$@")
    build_opencode2_launch_args 2>/dev/null
    assert_equal "${AGENT_LAUNCH_ARGS[*]}" "$expected"
}

# --- claude_should_add_skip_permissions ---------------------------------------

@test "claude: the skip-permissions flag is added without agent arguments" {
    run claude_should_add_skip_permissions
    assert_success
}

@test "claude: the flag is added for unrelated arguments" {
    AGENT_ARGS=(--model claude-sonnet-4-5 --version)
    run claude_should_add_skip_permissions
    assert_success
}

@test "claude: a user permission flag suppresses the skip-permissions flag" {
    local -a cases=(
        "--permission-mode default"
        "--permission-mode=plan"
        "--dangerously-skip-permissions"
        "--allow-dangerously-skip-permissions"
        "--model x --permission-mode acceptEdits --verbose"
    )
    local c
    for c in "${cases[@]}"; do
        read -ra AGENT_ARGS <<< "$c"
        run claude_should_add_skip_permissions
        assert_failure
    done
}

@test "claude: similar-looking flags do not suppress the skip-permissions flag" {
    AGENT_ARGS=(--permission-modes --skip-permissions --dangerously-skip-permissions-now)
    run claude_should_add_skip_permissions
    assert_success
}

@test "claude: permission flags after -- are still honoured" {
    # The scan does not stop at --; not adding the flag is the safe direction
    AGENT_ARGS=(-- --permission-mode plan)
    run claude_should_add_skip_permissions
    assert_failure
}

# --- opencode1_option_takes_value ---------------------------------------------

@test "opencode1_option_takes_value: value-taking options" {
    local opt
    for opt in --agent --model --port --prompt --session --dir --log-level -m -p -s -f -u; do
        run opencode1_option_takes_value "$opt"
        assert_success
    done
}

@test "opencode1_option_takes_value: boolean options and positionals" {
    local opt
    for opt in --print-logs --continue --help -c -h run ""; do
        run opencode1_option_takes_value "$opt"
        assert_failure
    done
}

# --- opencode1_command_accepts_default_agent ----------------------------------

@test "opencode1_command_accepts_default_agent: TUI, run and project paths accept --agent" {
    local cmd
    for cmd in "" run ./project /some/dir; do
        run opencode1_command_accepts_default_agent "$cmd"
        assert_success
    done
}

@test "opencode1_command_accepts_default_agent: other subcommands do not" {
    local cmd
    for cmd in acp agent attach auth serve session stats upgrade web models mcp github; do
        run opencode1_command_accepts_default_agent "$cmd"
        assert_failure
    done
}

# --- opencode1_should_add_default_agent ---------------------------------------

@test "opencode1: --agent build is added for the TUI, run and a project path" {
    local -a cases=("" "run hi" "myproject" "--print-logs run hi" "-m some/model run hi" "--model=x run")
    local c
    for c in "${cases[@]}"; do
        read -ra AGENT_ARGS <<< "$c"
        run opencode1_should_add_default_agent
        assert_success
    done
}

@test "opencode1: no default agent for subcommands without --agent" {
    local -a cases=("serve" "--print-logs serve" "--model x serve" "-m x auth login" "upgrade")
    local c
    for c in "${cases[@]}"; do
        read -ra AGENT_ARGS <<< "$c"
        run opencode1_should_add_default_agent
        assert_failure
    done
}

@test "opencode1: no default agent when the user passes --agent" {
    local -a cases=("--agent plan" "--agent=plan" "--agent plan run hi" "--agent=plan myproject")
    local c
    for c in "${cases[@]}"; do
        read -ra AGENT_ARGS <<< "$c"
        run opencode1_should_add_default_agent
        assert_failure
    done
}

@test "opencode1: the value of an option is not mistaken for a subcommand" {
    AGENT_ARGS=(-m serve)
    run opencode1_should_add_default_agent
    assert_success
}

@test "opencode1: arguments after -- are ignored" {
    AGENT_ARGS=(-- serve --agent plan)
    run opencode1_should_add_default_agent
    assert_success
}

# --- opencode2_option_takes_value ---------------------------------------------

@test "opencode2_option_takes_value: value-taking options" {
    local opt
    for opt in --server --session --prompt --model --agent --format --file --title --replay-limit --log-level --completions -s -m -f; do
        run opencode2_option_takes_value "$opt"
        assert_success
    done
}

@test "opencode2_option_takes_value: boolean options and positionals" {
    local opt
    for opt in --standalone --auto --yolo --continue --help -c run ""; do
        run opencode2_option_takes_value "$opt"
        assert_failure
    done
}

# --- build_opencode2_launch_args ----------------------------------------------

@test "opencode2: the TUI without arguments gets --standalone --auto" {
    assert_opencode2_launch "--standalone --auto"
}

@test "opencode2: run gets both flags after the command" {
    assert_opencode2_launch "run --standalone --auto hi" run hi
}

@test "opencode2: options with values before the command are skipped" {
    assert_opencode2_launch "--model x run --standalone --auto hi" --model x run hi
    assert_opencode2_launch "-m x run --standalone --auto hi" -m x run hi
    assert_opencode2_launch "--model=x run --standalone --auto hi" --model=x run hi
    assert_opencode2_launch "--log-level DEBUG models --standalone" --log-level DEBUG models
}

@test "opencode2: commands that accept only --standalone" {
    assert_opencode2_launch "api --standalone" api
    assert_opencode2_launch "models --standalone openai" models openai
    assert_opencode2_launch "stats --standalone" stats
    assert_opencode2_launch "mini --standalone" mini
    assert_opencode2_launch "reload --standalone" reload
}

@test "opencode2: session subcommands get --standalone after the subcommand" {
    local sub
    for sub in list delete export import; do
        assert_opencode2_launch "session $sub --standalone" session "$sub"
    done
    assert_opencode2_launch "session delete --standalone abc123" session delete abc123
}

@test "opencode2: auth subcommands get --standalone after the subcommand" {
    local sub
    for sub in list login logout export import switch; do
        assert_opencode2_launch "auth $sub --standalone" auth "$sub"
    done
    assert_opencode2_launch "auth login --standalone anthropic" auth login anthropic
}

@test "opencode2: unknown session/auth subcommands and bare session/auth get nothing" {
    assert_opencode2_launch "session" session
    assert_opencode2_launch "session frobnicate" session frobnicate
    assert_opencode2_launch "auth" auth
}

@test "opencode2: commands without the flags are left unchanged" {
    local cmd
    for cmd in upgrade update uninstall acp debug mcp plugin pair serve service; do
        assert_opencode2_launch "$cmd" "$cmd"
    done
    assert_opencode2_launch "serve --port 4096" serve --port 4096
}

@test "opencode2: a TUI project directory gets the flags in front" {
    assert_opencode2_launch "--standalone --auto ./my-project" ./my-project
    assert_opencode2_launch "--standalone --auto -c /path/to/project" -c /path/to/project
}

@test "opencode2: user permission flags suppress --auto" {
    local flag
    for flag in --auto --yolo --dangerously-skip-permissions; do
        assert_opencode2_launch "--standalone $flag" "$flag"
        assert_opencode2_launch "run --standalone $flag hi" run "$flag" hi
    done
}

@test "opencode2: a user --standalone is not duplicated" {
    assert_opencode2_launch "--auto --standalone" --standalone
    assert_opencode2_launch "run --auto --standalone hi" run --standalone hi
    assert_opencode2_launch "session list --standalone" session list --standalone
}

@test "opencode2: --server suppresses --standalone and logs a warning" {
    AGENT_ARGS=(--server http://localhost:4096 run hi)
    run build_opencode2_launch_args
    assert_output --partial "--server given"
    build_opencode2_launch_args 2>/dev/null
    assert_equal "${AGENT_LAUNCH_ARGS[*]}" "--server http://localhost:4096 run --auto hi"
}

@test "opencode2: --server=URL suppresses --standalone and logs a warning" {
    AGENT_ARGS=(--server=http://localhost:4096)
    run build_opencode2_launch_args
    assert_output --partial "--server given"
    build_opencode2_launch_args 2>/dev/null
    assert_equal "${AGENT_LAUNCH_ARGS[*]}" "--auto --server=http://localhost:4096"
}

@test "opencode2: --standalone alone logs no warning" {
    AGENT_ARGS=(--standalone run hi)
    run build_opencode2_launch_args
    assert_output ""
}

@test "opencode2: everything after -- is left untouched" {
    AGENT_ARGS=(run -- --standalone "two words" session list)
    build_opencode2_launch_args
    assert_equal "${#AGENT_LAUNCH_ARGS[@]}" 8
    assert_equal "${AGENT_LAUNCH_ARGS[0]}" run
    assert_equal "${AGENT_LAUNCH_ARGS[1]}" --standalone
    assert_equal "${AGENT_LAUNCH_ARGS[2]}" --auto
    assert_equal "${AGENT_LAUNCH_ARGS[3]}" --
    assert_equal "${AGENT_LAUNCH_ARGS[4]}" --standalone
    assert_equal "${AGENT_LAUNCH_ARGS[5]}" "two words"
    assert_equal "${AGENT_LAUNCH_ARGS[6]}" session
    assert_equal "${AGENT_LAUNCH_ARGS[7]}" list
}

@test "opencode2: a command after -- does not count as the command" {
    assert_opencode2_launch "--standalone --auto -- serve" -- serve
}

@test "opencode2: arguments with spaces are preserved as single words" {
    AGENT_ARGS=(run "Explain this repository")
    build_opencode2_launch_args
    assert_equal "${#AGENT_LAUNCH_ARGS[@]}" 4
    assert_equal "${AGENT_LAUNCH_ARGS[3]}" "Explain this repository"
}

# --- detect_opencode_version --------------------------------------------------

@test "detect_opencode_version reads a bare version number" {
    stub_command opencode '[[ "$1" == --version ]] && echo 1.4.2'
    AGENT_BIN="$STUB_DIR/opencode"
    detect_opencode_version
    assert_equal "$OPENCODE_MAJOR_VERSION" 1
}

@test "detect_opencode_version reads a version with a prefix" {
    stub_command opencode '[[ "$1" == --version ]] && echo "opencode 2.0.1"'
    AGENT_BIN="$STUB_DIR/opencode"
    detect_opencode_version
    assert_equal "$OPENCODE_MAJOR_VERSION" 2
}

@test "detect_opencode_version reads a multi-digit major version" {
    stub_command opencode 'echo "v12.3.0"'
    AGENT_BIN="$STUB_DIR/opencode"
    detect_opencode_version
    assert_equal "$OPENCODE_MAJOR_VERSION" 12
}

@test "detect_opencode_version assumes 2 with a warning for unreadable output" {
    stub_command opencode 'echo "something went wrong"'
    AGENT_BIN="$STUB_DIR/opencode"
    run detect_opencode_version
    assert_output --partial "Could not detect the OpenCode version"
    detect_opencode_version 2>/dev/null
    assert_equal "$OPENCODE_MAJOR_VERSION" 2
}

@test "detect_opencode_version assumes 2 when the binary fails" {
    stub_command opencode 'echo "1.4.2"; exit 1'
    AGENT_BIN="$STUB_DIR/opencode"
    run detect_opencode_version
    assert_output --partial "assuming OpenCode 2"
    detect_opencode_version 2>/dev/null
    assert_equal "$OPENCODE_MAJOR_VERSION" 2
}

@test "detect_opencode_version ignores the version printed on stderr" {
    stub_command opencode 'echo "1.4.2" >&2'
    AGENT_BIN="$STUB_DIR/opencode"
    detect_opencode_version 2>/dev/null
    assert_equal "$OPENCODE_MAJOR_VERSION" 2
}
