#!/usr/bin/env bats
# Unit tests of the config.yaml parser: scalar/comment/quote handling, flow
# lists and maps, parse_config_file edge cases (CRLF, BOM, tabs, document
# markers, removed keys), applying keys to the script's variables and the
# load order of the user, project and main-checkout config files.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
}

# Usage: write_config <path> <line...>
# Write the lines (newline-terminated) to <path>, creating parent directories.
write_config() {
    local path="$1"
    shift
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$@" > "$path"
}

# Usage: assert_config_warning <substring>
# Fail unless one of the buffered config warnings contains the substring.
assert_config_warning() {
    local msg
    for msg in "${CONFIG_LOG_MESSAGES[@]}"; do
        [[ "$msg" == *"$1"* ]] && return 0
    done
    batslib_print_kv_single_or_multi 8 \
        'expected' "$1" \
        'warnings' "$(printf '%s\n' "${CONFIG_LOG_MESSAGES[@]}")" \
        | batslib_decorate "config warning not found" | fail
}

assert_no_config_warnings() {
    if [[ ${#CONFIG_LOG_MESSAGES[@]} -ne 0 ]]; then
        printf '%s\n' "${CONFIG_LOG_MESSAGES[@]}" \
            | batslib_decorate "unexpected config warnings" | fail
    fi
}

# --- strip_yaml_comment -------------------------------------------------------

@test "strip_yaml_comment drops a comment preceded by whitespace" {
    run strip_yaml_comment "value   # comment"
    assert_output "value"
}

@test "strip_yaml_comment treats a leading # as a comment" {
    run strip_yaml_comment "# only a comment"
    assert_output ""
}

@test "strip_yaml_comment keeps a # that is not preceded by whitespace" {
    run strip_yaml_comment "ghcr.io/image#tag"
    assert_output "ghcr.io/image#tag"
}

@test "strip_yaml_comment trims surrounding whitespace" {
    run strip_yaml_comment "   /etc/java[0-9]*   "
    assert_output "/etc/java[0-9]*"
}

# --- parse_yaml_scalar --------------------------------------------------------

@test "parse_yaml_scalar returns an unquoted value without its comment" {
    local value
    parse_yaml_scalar "  plain value # comment" value
    assert_equal "$value" "plain value"
}

@test "parse_yaml_scalar keeps a # inside a double-quoted value" {
    local value
    parse_yaml_scalar '"value # not a comment"' value
    assert_equal "$value" "value # not a comment"
}

@test "parse_yaml_scalar drops a comment after the closing quote" {
    local value
    parse_yaml_scalar "'quoted' # comment" value
    assert_equal "$value" "quoted"
    assert_no_config_warnings
}

@test "parse_yaml_scalar unescapes double-quoted values" {
    local value
    parse_yaml_scalar '"say \"hi\" C:\\dir"' value
    assert_equal "$value" 'say "hi" C:\dir'
}

@test "parse_yaml_scalar unescapes doubled single quotes" {
    local value
    parse_yaml_scalar "'it''s'" value
    assert_equal "$value" "it's"
}

@test "parse_yaml_scalar keeps an empty quoted string as a non-null value" {
    local value=unset rc=0
    parse_yaml_scalar '""' value || rc=$?
    assert_equal "$rc" 0
    assert_equal "$value" ""
}

@test "parse_yaml_scalar keeps the colon in docker_image: ghcr.io/x:1" {
    local value
    parse_yaml_scalar "ghcr.io/x:1" value
    assert_equal "$value" "ghcr.io/x:1"
}

@test "parse_yaml_scalar returns 1 and an empty value for null forms" {
    local raw value rc
    for raw in "" "~" null Null NULL "# comment"; do
        value=unchanged rc=0
        parse_yaml_scalar "$raw" value || rc=$?
        assert_equal "$rc" 1
        assert_equal "$value" ""
    done
}

@test "parse_yaml_scalar warns about text after the closing quote" {
    local value
    parse_yaml_scalar '"a" trailing' value
    assert_equal "$value" "a"
    assert_config_warning "Ignoring unexpected text after quoted value: trailing"
}

@test "parse_yaml_scalar treats an unterminated quote literally with a warning" {
    local value
    parse_yaml_scalar '"open' value
    assert_equal "$value" '"open'
    assert_config_warning "Unterminated quoted value"
}

# --- parse_yaml_bool ----------------------------------------------------------

@test "parse_yaml_bool accepts true/yes/on and false/no/off case-insensitively" {
    local v
    for v in true True YES on; do
        run parse_yaml_bool "$v" docker file.yaml
        assert_output true
    done
    for v in false FALSE no Off; do
        run parse_yaml_bool "$v" docker file.yaml
        assert_output false
    done
}

@test "parse_yaml_bool fails fatally on an invalid boolean" {
    run parse_yaml_bool ture docker /x/config.yaml
    assert_failure 1
    assert_output --partial "Invalid boolean for 'docker' in /x/config.yaml: 'ture'"
}

# --- is_config_list_key -------------------------------------------------------

@test "is_config_list_key accepts exactly the list keys" {
    local key
    for key in whitelist blacklist host_ports allow_hosts agent_args; do
        run is_config_list_key "$key"
        assert_success
    done
    for key in env profile docker whitelist_files; do
        run is_config_list_key "$key"
        assert_failure
    done
}

# --- apply_config_list_item ---------------------------------------------------

@test "apply_config_list_item appends to the variable of each list key" {
    apply_config_list_item whitelist /opt/a f.yaml
    apply_config_list_item blacklist secrets/ f.yaml
    apply_config_list_item agent_args --model f.yaml
    apply_config_list_item host_ports 3773 f.yaml
    apply_config_list_item host_ports 8000-8010 f.yaml
    apply_config_list_item allow_hosts 192.168.1.5 f.yaml
    assert_equal "${WHITELIST_ENTRIES[*]}" "/opt/a"
    assert_equal "${BLACKLIST_PATHS[*]}" "secrets/"
    assert_equal "${CONFIG_AGENT_ARGS[*]}" "--model"
    assert_equal "${NETWORK_HOST_PORTS[*]}" "3773 8000-8010"
    assert_equal "${NETWORK_ALLOW_HOSTS[*]}" "192.168.1.5"
    assert_no_config_warnings
}

@test "apply_config_list_item rejects an invalid host port fatally" {
    run apply_config_list_item host_ports 70000 /x/config.yaml
    assert_failure 1
    assert_output --partial "Invalid host_ports entry in /x/config.yaml: '70000'"
}

@test "apply_config_list_item warns for a key that does not take a list" {
    apply_config_list_item profile work f.yaml
    assert_equal "$PROFILE" ""
    assert_config_warning "Key 'profile' in f.yaml does not accept a list"
}

# --- apply_config_scalar ------------------------------------------------------

@test "apply_config_scalar sets string keys" {
    apply_config_scalar agent opencode f.yaml false
    apply_config_scalar docker_image ghcr.io/x:1 f.yaml false
    apply_config_scalar network host f.yaml false
    assert_equal "$AGENT" opencode
    assert_equal "$SOCKET_PROXY_IMAGE" ghcr.io/x:1
    assert_equal "$NETWORK_MODE" host
    assert_equal "$NETWORK_MODE_SOURCE" f.yaml
}

@test "apply_config_scalar maps the boolean keys to their variables" {
    apply_config_scalar docker true f.yaml false
    apply_config_scalar venv yes f.yaml false
    apply_config_scalar gpg_agent on f.yaml false
    apply_config_scalar gitconfig false f.yaml false
    apply_config_scalar shared_skills no f.yaml false
    apply_config_scalar quiet true f.yaml false
    apply_config_scalar protect_project_config false "$DEFAULT_CONFIG_FILE" false
    assert_equal "$ENABLE_DOCKER" true
    assert_equal "$ENABLE_VENV" true
    assert_equal "$ENABLE_GPG_AGENT" true
    assert_equal "$MOUNT_GITCONFIG" false
    assert_equal "$SHARE_SKILLS" false
    assert_equal "$QUIET" true
    assert_equal "$PROTECT_PROJECT_CONFIG" false
}

@test "apply_config_scalar leaves a boolean unchanged when the value is null" {
    apply_config_scalar gitconfig "" f.yaml true
    assert_equal "$MOUNT_GITCONFIG" true
}

@test "apply_config_scalar exits on an invalid boolean" {
    run apply_config_scalar docker ture /x/config.yaml false
    assert_failure 1
    assert_output --partial "Invalid boolean for 'docker'"
}

@test "apply_config_scalar rejects an invalid network mode" {
    run apply_config_scalar network full /x/config.yaml false
    assert_failure 1
    assert_output --partial "Invalid value for 'network' in /x/config.yaml: 'full'"
}

@test "apply_config_scalar resets the network mode to the default on null" {
    apply_config_scalar network host f.yaml false
    apply_config_scalar network "" f.yaml true
    assert_equal "$NETWORK_MODE" ""
    assert_equal "$NETWORK_MODE_SOURCE" default
}

@test "apply_config_scalar records a user-level profile without a project profile" {
    apply_config_scalar profile work "$DEFAULT_CONFIG_FILE" false
    assert_equal "$PROFILE" work
    assert_equal "$PROFILE_SOURCE" "$DEFAULT_CONFIG_FILE"
    assert_equal "$PROJECT_PROFILE" ""
    assert_equal "$PROJECT_PROFILE_SOURCE" ""
}

@test "apply_config_scalar records a profile from a project file as the project profile" {
    apply_config_scalar profile work "$PROJECT_CONFIG_FILE" false
    assert_equal "$PROFILE" work
    assert_equal "$PROJECT_PROFILE" work
    assert_equal "$PROJECT_PROFILE_SOURCE" "$PROJECT_CONFIG_FILE"
}

@test "apply_config_scalar treats the main checkout's config.local.yaml as a project file" {
    MAIN_CHECKOUT_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/main/.ai-agent-sandbox/config.local.yaml"
    apply_config_scalar profile work "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" false
    assert_equal "$PROJECT_PROFILE" work
    assert_equal "$PROJECT_PROFILE_SOURCE" "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE"
}

@test "apply_config_scalar unsets the profile on a null value (profile: ~)" {
    apply_config_scalar profile work "$PROJECT_CONFIG_FILE" false
    apply_config_scalar profile "" "$PROJECT_CONFIG_LOCAL_FILE" true
    assert_equal "$PROFILE" ""
    assert_equal "$PROFILE_SOURCE" ""
    assert_equal "$PROJECT_PROFILE" ""
}

@test "apply_config_scalar ignores protect_project_config from a project file" {
    apply_config_scalar protect_project_config false "$PROJECT_CONFIG_FILE" false
    assert_equal "$PROTECT_PROJECT_CONFIG" true
    assert_config_warning "Ignoring 'protect_project_config' in $PROJECT_CONFIG_FILE"
}

@test "apply_config_scalar accepts a single scalar for a list key" {
    apply_config_scalar whitelist "/etc/java[0-9]*" f.yaml false
    assert_equal "${WHITELIST_ENTRIES[*]}" "/etc/java[0-9]*"
}

@test "apply_config_scalar warns about an unknown key" {
    apply_config_scalar colour blue f.yaml false
    assert_config_warning "Unknown configuration key 'colour' in f.yaml"
}

@test "apply_config_scalar warns about env given as a scalar" {
    apply_config_scalar env FOO f.yaml false
    assert_equal "${#ENV_VARS[@]}" 0
    assert_config_warning "Ignoring 'env' in f.yaml"
}

# --- apply_config_env_item ----------------------------------------------------

@test "apply_config_env_item pushes KEY=<raw value> to ENV_VARS" {
    apply_config_env_item FOO '  $HOME/bin  ' f.yaml
    assert_equal "${ENV_VARS[*]}" 'FOO=$HOME/bin'
}

@test "apply_config_env_item keeps quotes and drops a comment after them" {
    apply_config_env_item FOO '"a # b" # comment' f.yaml
    apply_config_env_item BAR "'x'" f.yaml
    assert_equal "${ENV_VARS[0]}" 'FOO="a # b"'
    assert_equal "${ENV_VARS[1]}" "BAR='x'"
}

@test "apply_config_env_item skips an invalid variable name" {
    apply_config_env_item 1BAD value f.yaml
    assert_equal "${#ENV_VARS[@]}" 0
    assert_config_warning "Skipping invalid environment variable name in f.yaml: 1BAD"
}

# --- parse_yaml_flow_list / parse_yaml_flow_map -------------------------------

@test "parse_yaml_flow_list applies every item of an inline list" {
    parse_yaml_flow_list whitelist "[/opt/a, 'b c', \"d\"] # comment" f.yaml
    assert_equal "${#WHITELIST_ENTRIES[@]}" 3
    assert_equal "${WHITELIST_ENTRIES[0]}" /opt/a
    assert_equal "${WHITELIST_ENTRIES[1]}" "b c"
    assert_equal "${WHITELIST_ENTRIES[2]}" d
}

@test "parse_yaml_flow_list adds nothing for an empty list" {
    parse_yaml_flow_list blacklist "[]" f.yaml
    assert_equal "${#BLACKLIST_PATHS[@]}" 0
}

@test "parse_yaml_flow_map applies every entry of an inline mapping" {
    parse_yaml_flow_map "{FOO: 1, BAR: \"two\"} # comment" f.yaml 3
    assert_equal "${ENV_VARS[0]}" FOO=1
    assert_equal "${ENV_VARS[1]}" 'BAR="two"'
}

@test "parse_yaml_flow_map warns about an invalid entry" {
    parse_yaml_flow_map "{FOO: 1, nonsense}" f.yaml 7
    assert_equal "${ENV_VARS[*]}" FOO=1
    assert_config_warning "f.yaml:7: invalid env entry 'nonsense'"
}

# --- parse_config_file --------------------------------------------------------

@test "parse_config_file reads scalars, block lists and comments" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" \
        "# comment" \
        "" \
        "agent: opencode   # trailing comment" \
        "docker: true" \
        "docker_image: ghcr.io/x:1" \
        "whitelist:" \
        "  - /opt/tools" \
        "  # comment inside the list" \
        "  - data/:rw" \
        "blacklist:" \
        "- secrets/" \
        "agent_args:" \
        "  - --model" \
        "  - sonnet"
    parse_config_file "$f"
    assert_equal "$AGENT" opencode
    assert_equal "$ENABLE_DOCKER" true
    assert_equal "$SOCKET_PROXY_IMAGE" ghcr.io/x:1
    assert_equal "${WHITELIST_ENTRIES[*]}" "/opt/tools data/:rw"
    assert_equal "${BLACKLIST_PATHS[*]}" "secrets/"
    assert_equal "${CONFIG_AGENT_ARGS[*]}" "--model sonnet"
    assert_no_config_warnings
}

@test "parse_config_file keeps a # inside a quoted value" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" 'agent: "value # not a comment"'
    parse_config_file "$f"
    assert_equal "$AGENT" "value # not a comment"
}

@test "parse_config_file handles CRLF line endings" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    printf 'agent: opencode\r\nwhitelist:\r\n  - /opt/a\r\nquiet: true\r\n' > "$f"
    parse_config_file "$f"
    assert_equal "$AGENT" opencode
    assert_equal "${WHITELIST_ENTRIES[*]}" /opt/a
    assert_equal "$QUIET" true
    assert_no_config_warnings
}

@test "parse_config_file strips a UTF-8 BOM on the first line" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    printf '\xEF\xBB\xBFagent: opencode\n' > "$f"
    parse_config_file "$f"
    assert_equal "$AGENT" opencode
    assert_no_config_warnings
}

@test "parse_config_file accepts tab indentation for lists and env" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    printf 'whitelist:\n\t- /opt/a\nenv:\n\tFOO: bar\n' > "$f"
    parse_config_file "$f"
    assert_equal "${WHITELIST_ENTRIES[*]}" /opt/a
    assert_equal "${ENV_VARS[*]}" FOO=bar
    assert_no_config_warnings
}

@test "parse_config_file skips --- and ... document markers" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "---" "agent: opencode" "..."
    parse_config_file "$f"
    assert_equal "$AGENT" opencode
    assert_no_config_warnings
}

@test "parse_config_file reads a file without a trailing newline" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    printf 'agent: opencode' > "$f"
    parse_config_file "$f"
    assert_equal "$AGENT" opencode
}

@test "parse_config_file keeps a glob with [ as a whitelist scalar" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "whitelist: /etc/java[0-9]*" "blacklist:" "  - '[abc]*.key'"
    parse_config_file "$f"
    assert_equal "${WHITELIST_ENTRIES[*]}" "/etc/java[0-9]*"
    assert_equal "${BLACKLIST_PATHS[*]}" "[abc]*.key"
    assert_no_config_warnings
}

@test "parse_config_file reads inline lists for list keys" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "whitelist: [/opt/a, /opt/b]  # comment" "host_ports: [3773]"
    parse_config_file "$f"
    assert_equal "${WHITELIST_ENTRIES[*]}" "/opt/a /opt/b"
    assert_equal "${NETWORK_HOST_PORTS[*]}" 3773
}

@test "parse_config_file reads an env block mapping" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" \
        "env:" \
        "  FOO: bar" \
        '  QUOTED: "a # b"  # comment' \
        "  EMPTY:" \
        "agent: opencode"
    parse_config_file "$f"
    assert_equal "${#ENV_VARS[@]}" 3
    assert_equal "${ENV_VARS[0]}" FOO=bar
    assert_equal "${ENV_VARS[1]}" 'QUOTED="a # b"'
    assert_equal "${ENV_VARS[2]}" EMPTY=
    assert_equal "$AGENT" opencode
}

@test "parse_config_file reads an env inline mapping" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "env: {FOO: bar, BAZ: 1}"
    parse_config_file "$f"
    assert_equal "${ENV_VARS[*]}" "FOO=bar BAZ=1"
}

@test "parse_config_file unsets the profile for profile: ~ and an empty profile:" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    PROFILE=work PROFILE_SOURCE=somewhere
    write_config "$f" "profile: ~"
    parse_config_file "$f"
    assert_equal "$PROFILE" ""
    assert_equal "$PROFILE_SOURCE" ""

    PROFILE=work
    write_config "$f" "profile:" "agent: opencode"
    parse_config_file "$f"
    assert_equal "$PROFILE" ""
    assert_equal "$AGENT" opencode

    PROFILE=work
    write_config "$f" "profile:"
    parse_config_file "$f"
    assert_equal "$PROFILE" ""
}

@test "parse_config_file warns about an unknown key and continues" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "colour: blue" "agent: opencode"
    parse_config_file "$f"
    assert_equal "$AGENT" opencode
    assert_config_warning "Unknown configuration key 'colour' in $f"
}

@test "parse_config_file fails on docker: ture" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "docker: ture"
    run parse_config_file "$f"
    assert_failure 1
    assert_output --partial "Invalid boolean for 'docker' in $f: 'ture'"
}

@test "parse_config_file fails on the removed *_files keys" {
    local f="$BATS_TEST_TMPDIR/config.yaml" key
    for key in whitelist_files blacklist_files env_files; do
        write_config "$f" "agent: opencode" "$key:" "  - x.txt"
        run parse_config_file "$f"
        assert_failure 1
        assert_output --partial "$f:2: '$key' is no longer supported"
        assert_output --partial "into the '${key%_files}' key"
    done
}

@test "parse_config_file warns about a list under a scalar key" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "agent:" "  - opencode" "  - other" "quiet: true"
    parse_config_file "$f"
    assert_equal "$AGENT" claudecode
    assert_equal "$QUIET" true
    assert_config_warning "$f:2: key 'agent' does not accept a list"
    assert_equal "${#CONFIG_LOG_MESSAGES[@]}" 1
}

@test "parse_config_file warns about a list item outside of a list" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "- stray"
    parse_config_file "$f"
    assert_config_warning "$f:1: list item outside of a list"
}

@test "parse_config_file warns about a nested mapping under a non-env key" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "whitelist:" "  nested: x" "  other: y" "agent: opencode"
    parse_config_file "$f"
    assert_equal "${#WHITELIST_ENTRIES[@]}" 0
    assert_equal "$AGENT" opencode
    assert_config_warning "$f:2: nested mapping under 'whitelist' is not supported"
    assert_equal "${#CONFIG_LOG_MESSAGES[@]}" 1
}

@test "parse_config_file warns about unsupported YAML syntax" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "agent: |" "profile: *anchor" "this is not yaml"
    parse_config_file "$f"
    assert_equal "$AGENT" claudecode
    assert_equal "$PROFILE" ""
    assert_config_warning "$f:1: unsupported YAML syntax for 'agent'"
    assert_config_warning "$f:2: unsupported YAML syntax for 'profile'"
    assert_config_warning "$f:3: unsupported syntax (ignored): this is not yaml"
}

@test "parse_config_file treats an unexpectedly indented key as top-level" {
    local f="$BATS_TEST_TMPDIR/config.yaml"
    write_config "$f" "  agent: opencode"
    parse_config_file "$f"
    assert_equal "$AGENT" opencode
    assert_config_warning "unexpected indentation, treating 'agent' as a top-level key"
}

# --- load_config_files --------------------------------------------------------

@test "load_config_files skips missing files without errors" {
    load_config_files
    assert_equal "${#CONFIG_FILES_LOADED[@]}" 0
    assert_no_config_warnings
}

@test "load_config_files loads user, project and main-checkout files in order" {
    MAIN_CHECKOUT_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/main/.ai-agent-sandbox/config.local.yaml"
    write_config "$DEFAULT_CONFIG_FILE" "agent: user" "whitelist: [/u]"
    write_config "$DEFAULT_CONFIG_LOCAL_FILE" "agent: user-local" "whitelist: [/ul]"
    write_config "$PROJECT_CONFIG_FILE" "agent: project" "whitelist: [/p]"
    write_config "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" "agent: main-local" "whitelist: [/m]"
    write_config "$PROJECT_CONFIG_LOCAL_FILE" "agent: project-local" "whitelist: [/pl]"
    load_config_files
    assert_equal "${CONFIG_FILES_LOADED[*]}" \
        "$DEFAULT_CONFIG_FILE $DEFAULT_CONFIG_LOCAL_FILE $PROJECT_CONFIG_FILE $MAIN_CHECKOUT_CONFIG_LOCAL_FILE $PROJECT_CONFIG_LOCAL_FILE"
    # Later files win for scalars, lists are merged in load order
    assert_equal "$AGENT" project-local
    assert_equal "${WHITELIST_ENTRIES[*]}" "/u /ul /p /m /pl"
}

@test "load_config_files lets each later file override the profile" {
    write_config "$DEFAULT_CONFIG_FILE" "profile: user"
    write_config "$DEFAULT_CONFIG_LOCAL_FILE" "profile: user-local"
    load_config_files
    assert_equal "$PROFILE" user-local
    assert_equal "$PROFILE_SOURCE" "$DEFAULT_CONFIG_LOCAL_FILE"
    assert_equal "$PROJECT_PROFILE" ""
}

@test "load_config_files records a profile from the main checkout as the project profile" {
    MAIN_CHECKOUT_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/main/.ai-agent-sandbox/config.local.yaml"
    write_config "$DEFAULT_CONFIG_FILE" "profile: user"
    write_config "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" "profile: work"
    load_config_files
    assert_equal "$PROFILE" work
    assert_equal "$PROJECT_PROFILE" work
    assert_equal "$PROJECT_PROFILE_SOURCE" "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE"
}

@test "load_config_files honours AI_AGENT_SANDBOX_CONFIG and _CONFIG_LOCAL" {
    export AI_AGENT_SANDBOX_CONFIG="$BATS_TEST_TMPDIR/alt/a.yaml"
    export AI_AGENT_SANDBOX_CONFIG_LOCAL="$BATS_TEST_TMPDIR/alt/b.yaml"
    load_sandbox_script
    write_config "$AI_AGENT_SANDBOX_CONFIG" "agent: a"
    write_config "$AI_AGENT_SANDBOX_CONFIG_LOCAL" "venv: true"
    load_config_files
    assert_equal "${CONFIG_FILES_LOADED[*]}" "$AI_AGENT_SANDBOX_CONFIG $AI_AGENT_SANDBOX_CONFIG_LOCAL"
    assert_equal "$AGENT" a
    assert_equal "$ENABLE_VENV" true
}
