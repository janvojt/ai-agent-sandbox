#!/usr/bin/env bats
# Unit tests of the environment entry parsing: strip_inline_comment,
# expand_env_value, parse_env_assignment and sandbox_setenv/set_sandbox_env
# (what they add to SANDBOX_ENV and BWRAP_ARGS).

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    BWRAP_ARGS=()
}

# --- strip_inline_comment -----------------------------------------------------

@test "strip_inline_comment removes a trailing comment and surrounding whitespace" {
    run strip_inline_comment "  /opt/tools   # build tools"
    assert_output /opt/tools
}

@test "strip_inline_comment cuts at the first # even without whitespace" {
    run strip_inline_comment "a#b # c"
    assert_output a
}

@test "strip_inline_comment turns a comment-only or blank line into an empty line" {
    run strip_inline_comment "   # just a comment"
    assert_output ""
    run strip_inline_comment $' \t '
    assert_output ""
}

@test "strip_inline_comment leaves a plain entry unchanged" {
    run strip_inline_comment "src/**/*.json:rw"
    assert_output "src/**/*.json:rw"
}

# --- expand_env_value ---------------------------------------------------------

@test "expand_env_value expands a leading tilde to HOME" {
    run expand_env_value "~/bin"
    assert_output "$TEST_HOME/bin"
}

@test "expand_env_value expands tildes after colons in path lists" {
    run expand_env_value "~/bin:/usr/bin:~/.local/bin"
    assert_output "$TEST_HOME/bin:/usr/bin:$TEST_HOME/.local/bin"
}

@test "expand_env_value does not expand a tilde in the middle of a value" {
    run expand_env_value "a~/b"
    assert_output "a~/b"
}

@test "expand_env_value expands \$VAR and \${VAR} from the host environment" {
    export ENV_TEST_HOST=host-value
    run expand_env_value 'x-$ENV_TEST_HOST-${ENV_TEST_HOST}y'
    assert_output "x-host-value-host-valuey"
}

@test "expand_env_value prefers values already set for the sandbox" {
    export ENV_TEST_VAR=from-host
    SANDBOX_ENV[ENV_TEST_VAR]=from-sandbox
    run expand_env_value '$ENV_TEST_VAR'
    assert_output from-sandbox
}

@test "expand_env_value expands undefined variables to empty" {
    unset ENV_TEST_UNDEFINED
    run expand_env_value 'a${ENV_TEST_UNDEFINED}b$ENV_TEST_UNDEFINED'
    assert_output ab
}

@test "expand_env_value ignores shell variables that are not exported" {
    ENV_TEST_NOT_EXPORTED=secret
    run expand_env_value '$ENV_TEST_NOT_EXPORTED'
    assert_output ""
}

@test "expand_env_value turns \\\$ into a literal dollar" {
    export ENV_TEST_HOST=host-value
    run expand_env_value 'cost \$ENV_TEST_HOST'
    assert_output 'cost $ENV_TEST_HOST'
}

@test "expand_env_value keeps dollars that do not start a variable name" {
    run expand_env_value 'a$ $1 ${1} end$'
    assert_output 'a$ $1 ${1} end$'
}

# --- parse_env_assignment -----------------------------------------------------

@test "parse_env_assignment splits a plain KEY=value" {
    local key="" value=""
    parse_env_assignment "API_TOKEN=secret" key value
    assert_equal "$key" API_TOKEN
    assert_equal "$value" secret
}

@test "parse_env_assignment accepts an export prefix and whitespace around =" {
    local key="" value=""
    parse_env_assignment "  export   MY_VAR =  some value  " key value
    assert_equal "$key" MY_VAR
    assert_equal "$value" "some value"
}

@test "parse_env_assignment accepts an empty value" {
    local key="" value="unchanged"
    parse_env_assignment "EMPTY=" key value
    assert_equal "$key" EMPTY
    assert_equal "$value" ""
}

@test "parse_env_assignment splits at the first = only" {
    local key="" value=""
    parse_env_assignment "OPTS=a=b=c" key value
    assert_equal "$key" OPTS
    assert_equal "$value" "a=b=c"
}

@test "parse_env_assignment strips a comment after whitespace from unquoted values" {
    local key="" value=""
    parse_env_assignment "COLOR=blue   # the color" key value
    assert_equal "$value" blue
}

@test "parse_env_assignment keeps a # that is not preceded by whitespace" {
    local key="" value=""
    parse_env_assignment "URL=http://host/#anchor" key value
    assert_equal "$value" "http://host/#anchor"
}

@test "parse_env_assignment removes double quotes and keeps # inside them" {
    local key="" value=""
    parse_env_assignment 'MSG="hello # not a comment"' key value
    assert_equal "$value" "hello # not a comment"
}

@test "parse_env_assignment expands variables and tildes in double-quoted values" {
    export ENV_TEST_HOST=host-value
    local key="" value=""
    parse_env_assignment 'P="~/bin:$ENV_TEST_HOST"' key value
    assert_equal "$value" "$TEST_HOME/bin:host-value"
}

@test "parse_env_assignment expands variables in unquoted values" {
    export ENV_TEST_HOST=host-value
    local key="" value=""
    parse_env_assignment 'P=${ENV_TEST_HOST}/x' key value
    assert_equal "$value" "host-value/x"
}

@test "parse_env_assignment keeps single-quoted values literal" {
    export ENV_TEST_HOST=host-value
    local key="" value=""
    parse_env_assignment "LITERAL='~/\$ENV_TEST_HOST # x'" key value
    assert_equal "$key" LITERAL
    assert_equal "$value" '~/$ENV_TEST_HOST # x'
}

@test "parse_env_assignment rejects empty lines, comments and lines without =" {
    local line
    for line in "" "   " "# KEY=value" "  # comment" "JUST_A_NAME" "export"; do
        run parse_env_assignment "$line" key value
        assert_failure
    done
}

@test "parse_env_assignment rejects invalid variable names with a warning" {
    local line
    for line in "1BAD=x" "BAD-NAME=x" "=value" "A B=x"; do
        run parse_env_assignment "$line" key value
        assert_failure
        assert_output --partial "Skipping invalid environment variable name"
    done
}

@test "parse_env_assignment prints no warning under QUIET" {
    QUIET=true
    run parse_env_assignment "1BAD=x" key value
    assert_failure
    assert_output ""
}

# --- sandbox_setenv / set_sandbox_env ----------------------------------------

@test "sandbox_setenv adds --setenv to BWRAP_ARGS and records the value" {
    sandbox_setenv FOO "bar baz"
    assert_equal "${#BWRAP_ARGS[@]}" 3
    assert_args_contain BWRAP_ARGS --setenv FOO "bar baz"
    assert_equal "${SANDBOX_ENV[FOO]}" "bar baz"
}

@test "sandbox_setenv overwrites a recorded value and appends another --setenv" {
    sandbox_setenv FOO one
    sandbox_setenv FOO two
    assert_equal "${SANDBOX_ENV[FOO]}" two
    assert_equal "${BWRAP_ARGS[*]}" "--setenv FOO one --setenv FOO two"
}

@test "set_sandbox_env parses the assignment and sets it in the sandbox" {
    set_sandbox_env 'GREETING="hello world"' "test" 2>/dev/null
    assert_equal "${BWRAP_ARGS[*]}" "--setenv GREETING hello world"
    assert_args_contain BWRAP_ARGS --setenv GREETING "hello world"
    assert_equal "${SANDBOX_ENV[GREETING]}" "hello world"
}

@test "set_sandbox_env logs the variable name but not its value" {
    run set_sandbox_env "API_TOKEN=supersecret" "test"
    assert_success
    assert_output --partial "Environment variable: API_TOKEN"
    refute_output --partial supersecret
}

@test "set_sandbox_env lets later entries reference earlier ones" {
    export PATH_TEST_BASE=/host/bin
    set_sandbox_env 'PATH_TEST_BASE=/sandbox/bin' "first" 2>/dev/null
    set_sandbox_env 'PATH_TEST="~/bin:$PATH_TEST_BASE"' "second" 2>/dev/null
    assert_equal "${SANDBOX_ENV[PATH_TEST]}" "$TEST_HOME/bin:/sandbox/bin"
    assert_args_contain BWRAP_ARGS --setenv PATH_TEST "$TEST_HOME/bin:/sandbox/bin"
}

@test "set_sandbox_env skips invalid entries without failing" {
    set_sandbox_env "not an assignment" "the test" 2>/dev/null
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_equal "${#SANDBOX_ENV[@]}" 0
    run set_sandbox_env "1BAD=x" "the test"
    assert_success
    assert_output --partial "Skipping invalid environment entry from the test"
}

# --- Host environment allow-list ---------------------------------------------------

@test "host_env_allowed accepts the listed names and prefixes only" {
    local name
    for name in USER LANG LC_ALL TZ HTTPS_PROXY JAVA_HOME ANTHROPIC_API_KEY \
        CLAUDE_CODE_OAUTH_TOKEN CLAUDECODE OPENCODE_CONFIG T3CODE_THREAD_ID \
        MAX_THINKING_TOKENS GIT_AUTHOR_EMAIL; do
        host_env_allowed "$name" || fail "$name should be allowed"
    done
    for name in GITHUB_TOKEN AWS_SECRET_ACCESS_KEY NPM_TOKEN DATABASE_URL \
        DBUS_SESSION_BUS_ADDRESS DISPLAY WAYLAND_DISPLAY XAUTHORITY SSH_AUTH_SOCK \
        LD_PRELOAD LD_LIBRARY_PATH GIT_SSH_COMMAND GIT_ASKPASS TMPDIR DOCKER_HOST \
        PATHX CLAUDE XLANG; do
        if host_env_allowed "$name"; then fail "$name should be hidden"; fi
    done
}

@test "filter_host_environment removes every hidden exported variable" {
    export GITHUB_TOKEN=secret DISPLAY=:0 ANTHROPIC_API_KEY=key LANG=C.UTF-8
    exported_test_function() { echo hi; }
    export -f exported_test_function
    run bash -c 'source "$1"; set +eu; e=$(command -v env); filter_host_environment; "$e"' _ "$SANDBOX_SCRIPT"
    assert_success
    refute_line --partial GITHUB_TOKEN=
    refute_line --partial DISPLAY=
    refute_line --regexp '^PATH='
    refute_line --partial BASH_FUNC_
    assert_line ANTHROPIC_API_KEY=key
    assert_line LANG=C.UTF-8
}

@test "hidden_host_env_names lists names only" {
    export GITHUB_TOKEN=very-secret-value
    run hidden_host_env_names
    assert_line GITHUB_TOKEN
    refute_output --partial very-secret-value
}

@test "env: in a project file cannot expand hidden host variables" {
    export GITHUB_TOKEN=secret LANG=C.UTF-8
    BWRAP_ARGS=()
    run set_sandbox_env 'TOKEN=$GITHUB_TOKEN-${LANG}' "$PROJECT_CONFIG_DIR/config.yaml"
    assert_output --partial "Not expanding \$GITHUB_TOKEN in $PROJECT_CONFIG_DIR/config.yaml"
    set_sandbox_env 'TOKEN=$GITHUB_TOKEN-${LANG}' "$PROJECT_CONFIG_DIR/config.yaml" 2>/dev/null
    assert_equal "${SANDBOX_ENV[TOKEN]}" "-C.UTF-8"
}

@test "env: in a user-level file and --env may expand any host variable" {
    export GITHUB_TOKEN=secret
    BWRAP_ARGS=()
    set_sandbox_env 'A=$GITHUB_TOKEN' "$DEFAULT_CONFIG_FILE"
    set_sandbox_env 'B=$GITHUB_TOKEN' --env
    assert_equal "${SANDBOX_ENV[A]}" secret
    assert_equal "${SANDBOX_ENV[B]}" secret
}
