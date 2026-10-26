#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configuration
DEFAULT_WHITELIST_FILE="${AI_AGENT_SANDBOX_WHITELIST:-$HOME/.config/ai-agent-sandbox/whitelist.txt}"
DEFAULT_BLACKLIST_FILE="${AI_AGENT_SANDBOX_BLACKLIST:-$HOME/.config/ai-agent-sandbox/blacklist.txt}"
DEFAULT_ENV_FILE="${AI_AGENT_SANDBOX_ENV:-$HOME/.config/ai-agent-sandbox/.env}"
DEFAULT_ENV_LOCAL_FILE="${AI_AGENT_SANDBOX_ENV_LOCAL:-$HOME/.config/ai-agent-sandbox/.env.local}"
WORKING_DIR="$(pwd)"
PROJECT_WHITELIST_FILE="$WORKING_DIR/.ai-agent-sandbox/whitelist.txt"
PROJECT_BLACKLIST_FILE="$WORKING_DIR/.ai-agent-sandbox/blacklist.txt"
PROJECT_ENV_FILE="$WORKING_DIR/.ai-agent-sandbox/.env"
PROJECT_ENV_LOCAL_FILE="$WORKING_DIR/.ai-agent-sandbox/.env.local"
DEFAULT_CONFIG_FILE="${AI_AGENT_SANDBOX_CONFIG:-$HOME/.config/ai-agent-sandbox/config.yaml}"
DEFAULT_CONFIG_LOCAL_FILE="${AI_AGENT_SANDBOX_CONFIG_LOCAL:-$HOME/.config/ai-agent-sandbox/config.local.yaml}"
PROJECT_CONFIG_DIR="$WORKING_DIR/.ai-agent-sandbox"
PROJECT_CONFIG_FILE="$PROJECT_CONFIG_DIR/config.yaml"
PROJECT_CONFIG_LOCAL_FILE="$PROJECT_CONFIG_DIR/config.local.yaml"
# config.local.yaml of the main checkout, used by a git worktree without its own
MAIN_CHECKOUT_CONFIG_LOCAL_FILE=""
# Profile requested by the project-level config files (checked against
# AI_AGENT_SANDBOX_PROFILE, see check_project_profile)
PROJECT_PROFILE=""
PROJECT_PROFILE_SOURCE=""
CONFIG_FILES_LOADED=()
CONFIG_LOG_MESSAGES=()
CONFIG_AGENT_ARGS=()
WHITELIST_ENTRIES=()
PROFILE=""
PROFILE_SOURCE=""
PROFILES_DIR="${AI_AGENT_SANDBOX_PROFILES_DIR:-$HOME/.local/share/ai-agent-sandbox/profiles}"
PROFILE_HOME=""
LIST_PROFILES=false
STRICT_PROFILE=false
ALLOW_HOME_WORKDIR=false
# Agent called with nothing but --version/-v (health checks of orchestrators)
VERSION_QUERY=false
MIGRATE_PROJECT_CONFIG=false
PROTECT_PROJECT_CONFIG=true
# Deprecated whitelist.txt / blacklist.txt / .env files still in use
WHITELIST_FILES=()
BLACKLIST_FILES=()
ENV_FILES=()
WHITELIST_PATHS_RO=()
WHITELIST_PATHS_RW=()
BLACKLIST_PATHS=()
ENV_VARS=()
declare -A SANDBOX_ENV=()
BLACKLISTED_DIRS=()
BLACKLIST_SEARCH_ROOTS=()
WHITELIST_OVERRIDE_ARGS=()
EXPLICIT_WHITELIST=false
EXPLICIT_BLACKLIST=false
QUIET=false
DRY_RUN=false
AGENT="claudecode"
ENABLE_DOCKER=false
ENABLE_VENV=false
MOUNT_GITCONFIG=true
SHARE_SKILLS=true
ENABLE_GPG_AGENT=false
GPG_HOST_EXTRA_SOCKET=""
GPG_SANDBOX_HOME=""
# Network isolation (see resolve_network_mode): isolated (own network namespace
# with user-mode networking, host loopback and private ranges blocked), host
# (shared host network) or none (no network at all)
NETWORK_MODE=""
NETWORK_MODE_SOURCE="default"
NETWORK_MODE_DEFAULT="isolated"
NETWORK_HOST_PORTS=()
NETWORK_ALLOW_HOSTS=()
NETWORK_TMP_DIR=""
NETWORK_INFO_FD=""
NETWORK_BLOCK_FD=""
PASTA_BIN=""
NSENTER_BIN=""
UNSHARE_BIN=""
SANDBOX_USERNS_FD=""
SANDBOX_USERNS2_FD=""
IP_BIN=""
# Addressing of the isolated namespace: a /24 of link-local space nobody routes,
# so the namespace never sits on one of the blocked subnets (the host's own IPv4
# subnet included). pasta proxies connections through host sockets, so the
# address inside is never visible to peers. The DNS address must be a plain
# host address of the subnet: in a /30 it would be the broadcast address and
# every query would fail with EACCES ("permission denied").
NETWORK_IFNAME="sandbox0"
NETWORK_NS_ADDR4="169.254.2.1/24"
NETWORK_GW4="169.254.2.2"
NETWORK_DNS4="169.254.2.3"
# The IPv6 DNS address is in the documentation prefix (never routed), so it
# needs no exception from the blocked ranges; pasta intercepts port 53 traffic
NETWORK_DNS6="2001:db8:a1a9::53"
NETWORK_DNS_FORWARD_ARGS=()
SANDBOX_CHILD_PID=""
NETWORK_BLOCKED_V4=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10)
NETWORK_BLOCKED_V6=(fc00::/7 fe80::/10)
# Route metrics: an allow route must beat a block route of the same prefix
NETWORK_ALLOW_METRIC=10
NETWORK_BLOCK_METRIC=100
SOCKET_PROXY_IMAGE="${AI_AGENT_SANDBOX_DOCKER_PROXY:-ghcr.io/wollomatic/socket-proxy:1}"
PROXY_CONTAINER_NAME=""
PROXY_SOCKET_PATH=""
PROXY_SOCKET_DIR=""
VENV_PATH=""
VENV_BIN_DIR=""
CLAUDE_HOST_BIN="$HOME/.local/bin/claude"
CLAUDE_NATIVE_DIR="$HOME/.local/share/claude"
CLAUDE_SANDBOX_BIN_DIR="$HOME/.local/share/ai-agent-sandbox/claude-bin"
CLAUDE_SANDBOX_WORK_DIR="$HOME/.local/share/ai-agent-sandbox/claude-work"
CLAUDE_NATIVE_INSTALL=false
DOCKER_COMPOSE_PLUGIN_DIRS=(
    "$HOME/.docker/cli-plugins"
    /usr/local/lib/docker/cli-plugins
    /usr/local/libexec/docker/cli-plugins
    /usr/lib/docker/cli-plugins
    /usr/libexec/docker/cli-plugins
)

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [-- AGENT_ARGS...]

Securely run AI coding agents in a sandboxed environment using bubblewrap.

OPTIONS:
    --agent, -a AGENT      AI coding agent to use: claudecode (default) or opencode
    --profile, -p NAME      Use a named agent profile (separate login, settings, memory);
                            'default' is the host configuration. New profiles start empty.
    --list-profiles         List available profiles and exit
    --strict-profile        A missing AI_AGENT_SANDBOX_PROFILE counts as 'default' when
                            checking a profile pinned by the project (for orchestrator
                            wrappers, e.g. T3 Code)
    --allow-home-workdir    Allow running in your home directory or one of its parents
                            (refused by default: the agent would get read-write access
                            to your whole home directory)
    --migrate-project-conf  Migrate legacy .ai-agent-sandbox/ files (whitelist.txt,
                            blacklist.txt, .env, .env.local) into config.yaml and exit
    --env, -e KEY=VALUE     Set environment variable inside sandbox (can be specified multiple times)
    --whitelist-path PATH   Directly whitelist a path (read-only, can be specified multiple times)
    --whitelist-path-rw PATH Directly whitelist a path (read-write, can be specified multiple times)
    --blacklist-path PATH   Directly blacklist a path (relative to working dir, can be specified multiple times)
    --enable-docker, -d     Enable Docker access via filtered socket proxy
    --no-docker             Disable Docker access (overrides config files)
    --venv                  Include active Python virtual environment in sandbox PATH
    --no-venv               Do not include the virtual environment (overrides config files)
    --gitconfig             Mount ~/.gitconfig read-only into the sandbox (default)
    --no-gitconfig          Do not mount ~/.gitconfig into the sandbox
    --shared-skills         Share the host's skills with every profile (default)
    --no-shared-skills      Profiles only see their own skills
    --gpg-agent             Forward the host gpg-agent for GPG commit signing (public keys only)
    --no-gpg-agent          Do not forward the gpg-agent (overrides config files)
    --no-protect-project-config
                            Mount .ai-agent-sandbox/ read-write instead of read-only
    --docker-image IMAGE    Socket proxy image (default: ghcr.io/wollomatic/socket-proxy:1)
    --network MODE          Network access: isolated (default: internet only, host
                            loopback and private networks blocked), host (share the
                            host network) or none (no network)
    --host-port PORT        Make a host loopback TCP port (or range a-b) reachable
                            at localhost inside the sandbox (isolated mode, repeatable)
    --allow-host ADDR       Allow an IP, CIDR range or hostname that would otherwise be
                            blocked as a private network (isolated mode, repeatable)
    --dry-run              Start bash shell instead of agent (for testing)
    --quiet, -q            Suppress informational output (faster startup)
    --verbose, -v          Show detailed output (default)
    -h, --help             Show this help message

CONFIGURATION FILES (automatically included if they exist):
    1. User-level (created with a default whitelist/blacklist on first run):
       - $DEFAULT_CONFIG_FILE
       - $DEFAULT_CONFIG_LOCAL_FILE
    2. Project-level (if present):
       - .ai-agent-sandbox/config.yaml (in working directory)
       - .ai-agent-sandbox/config.local.yaml (in working directory, personal overrides;
         in a git worktree without one, the main checkout's file is used)
    Precedence: user config < user local config < project config
                < project local config < AI_AGENT_SANDBOX_PROFILE
                < command-line options
    A profile set in a project file is not overridden by AI_AGENT_SANDBOX_PROFILE:
    a different value there is an error (--profile still overrides). With
    --strict-profile, a missing AI_AGENT_SANDBOX_PROFILE counts as 'default' for this check.

DEPRECATED LEGACY FILES:
    whitelist.txt, blacklist.txt, .env and .env.local next to the config files
    above are deprecated and will no longer be supported in a future release.
    They are ignored at a level (user or project) that has a config.yaml or
    config.local.yaml; otherwise they are still used. A warning is printed in
    both cases. Starting in a terminal offers to migrate the user-level files;
    project-level files are migrated with --migrate-project-conf.

CONFIGURATION FILE FORMAT:
    Config:    YAML (flat subset). Keys: profile, agent, network, docker, docker_image, venv,
                gitconfig, shared_skills, gpg_agent, quiet,
                protect_project_config (user-level only),
                whitelist, blacklist, host_ports, allow_hosts, agent_args (lists),
                env (KEY: VALUE mapping)
    whitelist: Absolute or relative paths/patterns that the agent can read
                Relative paths are resolved relative to working directory
                Default: read-only bind mount
                Suffix with :rw for read-write bind (e.g., /path/to/dir:rw or data/:rw)
                Supports glob patterns: /etc/java* or src/** will expand to all matching paths
                Prefix with ! to override blacklist for a specific path (applied after blacklist)
    blacklist: Paths/patterns relative to working directory that the agent cannot access
    env:       KEY: VALUE entries to expose inside the sandbox

PROFILES:
    Profile data is stored under $PROFILES_DIR/<name>/home
    and mirrors the home directory layout (e.g. .claude/, .claude.json). The agent
    binary stays shared; only configuration, credentials and memory are per profile.
    Skills from the host's ~/.claude/skills are visible in every profile; skills
    created inside a profile are stored in that profile (--no-shared-skills disables).
    OpenCode gets ~/.config/opencode/skills, ~/.claude/skills and ~/.agents/skills.

NETWORK:
    By default the sandbox gets its own network namespace with user-mode
    networking (pasta, package passt): the internet is reachable, the host's
    loopback services and private networks (10/8, 172.16/12, 192.168/16,
    169.254/16, 100.64/10, fc00::/7, fe80::/10, the host's own subnets) are not.
    Servers started inside are published on the host like before. Use
    --host-port / host_ports for host services (T3 Code: --host-port 3773, a
    database published by Docker: --host-port 5432) and --allow-host /
    allow_hosts for machines on the LAN. --network host restores full access.
    Environment variable AI_AGENT_SANDBOX_NETWORK sets the mode too.

ORCHESTRATORS:
    T3 Code and similar tools can use a two-line wrapper script as the agent
    binary:  exec $0 --quiet --host-port 3773 -- "\$@"
    The orchestrator stays on the host, the agents it launches run sandboxed.
    Git worktrees are supported (the linked .git directory is mounted) and a
    --permission-mode passed by the caller is respected.

EXAMPLES:
    $0
    $0 --profile work
    $0 --list-profiles
    $0 --agent opencode
    $0 --env API_TOKEN=secret
    $0 --whitelist-path /var/run/docker.sock
    $0 --whitelist-path-rw /shared/data
    $0 --blacklist-path .env --blacklist-path secrets/
    $0 --venv
    $0 --gpg-agent
    $0 --network host
    $0 --host-port 5432 --allow-host 192.168.1.50
    $0 -- --model claude-sonnet-4-5
    $0 -a opencode -- run -m deepseek/deepseek-chat "Explain this repository"

EOF
    exit 1
}

# Helper function for conditional output
log_info() {
    if [[ "$QUIET" = false ]]; then
        echo -e "$@" >&2
    fi
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

validate_network_mode() {
    case "$1" in
        isolated|host|none) return 0 ;;
    esac
    return 1
}

# A TCP port or an inclusive range first-last, as pasta accepts it
validate_host_port() {
    local spec="$1" first last
    [[ "$spec" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]] || return 1
    first=${BASH_REMATCH[1]}
    last=${BASH_REMATCH[3]:-$first}
    (( first >= 1 && first <= 65535 && last >= first && last <= 65535 ))
}

# Removes duplicates from the named array (config files and flags are merged)
dedupe_array() {
    local -n _da_ref="$1"
    local -A seen=()
    local -a out=()
    local item
    for item in "${_da_ref[@]}"; do
        [[ -n "${seen[$item]:-}" ]] && continue
        seen[$item]=1
        out+=("$item")
    done
    _da_ref=("${out[@]}")
}

# --- Configuration file (config.yaml) support ---------------------------------
#
# Config files are parsed BEFORE the command line so that command-line flags
# override them. Messages from the parser are buffered until --quiet/--verbose
# are known; fatal errors are reported immediately.

config_warn() {
    CONFIG_LOG_MESSAGES+=("${YELLOW}⚠${NC} $*")
}

config_error() {
    echo -e "${RED}Error: $*${NC}" >&2
    exit 1
}

flush_config_log() {
    local msg
    for msg in "${CONFIG_LOG_MESSAGES[@]}"; do
        log_info "$msg"
    done
    CONFIG_LOG_MESSAGES=()
}

is_config_list_key() {
    case "$1" in
        whitelist|blacklist|host_ports|allow_hosts|agent_args)
            return 0
            ;;
    esac
    return 1
}

# Strip a trailing comment from an unquoted YAML scalar. A '#' only starts a
# comment at the beginning of the value or when preceded by whitespace, so
# values like ghcr.io/image#tag or glob patterns stay intact.
strip_yaml_comment() {
    local value="$1"
    if [[ "$value" == "#"* ]]; then
        value=""
    else
        value="${value%%[[:space:]]#*}"
    fi
    trim_whitespace "$value"
}

# Normalize a raw YAML scalar into the variable named by $2: handles single and
# double quotes (a trailing comment after the closing quote is dropped) and
# strips comments from unquoted values. Returns 1 for null (~, null, empty).
# Must not be called in a subshell: it may buffer warnings.
parse_yaml_scalar() {
    local raw="$1"
    local out_ref="$2"
    local _pys_value _pys_quote _pys_prefix _pys_idx _pys_rest

    raw=$(trim_whitespace "$raw")
    if [[ "$raw" == \"* || "$raw" == \'* ]]; then
        _pys_quote="${raw:0:1}"
        _pys_prefix="${raw%"$_pys_quote"*}"
        _pys_idx=${#_pys_prefix}
        if [[ $_pys_idx -gt 0 ]]; then
            _pys_value="${raw:1:_pys_idx-1}"
            _pys_rest=$(trim_whitespace "${raw:_pys_idx+1}")
            if [[ -n "$_pys_rest" && "$_pys_rest" != "#"* ]]; then
                config_warn "Ignoring unexpected text after quoted value: $_pys_rest"
            fi
            if [[ "$_pys_quote" == '"' ]]; then
                _pys_value="${_pys_value//\\\"/\"}"
                _pys_value="${_pys_value//\\\\/\\}"
            else
                _pys_value="${_pys_value//\'\'/\'}"
            fi
            printf -v "$out_ref" '%s' "$_pys_value"
            return 0
        fi
        config_warn "Unterminated quoted value treated literally: $raw"
    fi

    _pys_value=$(strip_yaml_comment "$raw")
    case "$_pys_value" in
        ""|"~"|null|Null|NULL)
            printf -v "$out_ref" '%s' ""
            return 1
            ;;
    esac
    printf -v "$out_ref" '%s' "$_pys_value"
    return 0
}

parse_yaml_bool() {
    local value="$1" key="$2" file="$3"
    case "${value,,}" in
        true|yes|on) echo true ;;
        false|no|off) echo false ;;
        *) config_error "Invalid boolean for '$key' in $file: '$value' (expected true or false)" ;;
    esac
}

apply_config_list_item() {
    local key="$1" item="$2" file="$3"
    case "$key" in
        whitelist)
            WHITELIST_ENTRIES+=("$item")
            ;;
        blacklist)
            BLACKLIST_PATHS+=("$item")
            ;;
        agent_args)
            CONFIG_AGENT_ARGS+=("$item")
            ;;
        host_ports)
            validate_host_port "$item" || config_error "Invalid host_ports entry in $file: '$item' (expected a TCP port or range a-b)"
            NETWORK_HOST_PORTS+=("$item")
            ;;
        allow_hosts)
            NETWORK_ALLOW_HOSTS+=("$item")
            ;;
        *)
            config_warn "Key '$key' in $file does not accept a list (ignored)"
            ;;
    esac
}

# is_null=true means the key was present without a value (or ~/null)
apply_config_scalar() {
    local key="$1" value="$2" file="$3" is_null="$4"
    local bool

    case "$key" in
        profile)
            if [[ "$is_null" = true ]]; then
                PROFILE=""
                PROFILE_SOURCE=""
            else
                PROFILE="$value"
                PROFILE_SOURCE="$file"
            fi
            if is_project_config_file "$file"; then
                PROJECT_PROFILE="$PROFILE"
                PROJECT_PROFILE_SOURCE="$PROFILE_SOURCE"
            fi
            ;;
        agent)
            [[ "$is_null" = true ]] || AGENT="$value"
            ;;
        docker_image)
            [[ "$is_null" = true ]] || SOCKET_PROXY_IMAGE="$value"
            ;;
        network)
            if [[ "$is_null" = true ]]; then
                NETWORK_MODE=""
                NETWORK_MODE_SOURCE="default"
            else
                validate_network_mode "$value" || config_error "Invalid value for 'network' in $file: '$value' (expected isolated, host or none)"
                NETWORK_MODE="$value"
                NETWORK_MODE_SOURCE="$file"
            fi
            ;;
        docker|venv|gpg_agent|gitconfig|shared_skills|quiet|protect_project_config)
            [[ "$is_null" = true ]] && return 0
            bool=$(parse_yaml_bool "$value" "$key" "$file") || exit 1
            case "$key" in
                docker) ENABLE_DOCKER="$bool" ;;
                venv) ENABLE_VENV="$bool" ;;
                gpg_agent) ENABLE_GPG_AGENT="$bool" ;;
                gitconfig) MOUNT_GITCONFIG="$bool" ;;
                shared_skills) SHARE_SKILLS="$bool" ;;
                quiet) QUIET="$bool" ;;
                protect_project_config)
                    # The project itself must not be able to switch off the
                    # protection of its own sandbox configuration
                    if is_project_config_file "$file"; then
                        config_warn "Ignoring '$key' in $file (only allowed in user-level config files or on the command line)"
                    else
                        PROTECT_PROJECT_CONFIG="$bool"
                    fi
                    ;;
            esac
            ;;
        env)
            config_warn "Ignoring '$key' in $file: expected an indented KEY: VALUE mapping"
            ;;
        *)
            if is_config_list_key "$key"; then
                # A single scalar is accepted as a one-item list
                [[ "$is_null" = true ]] || apply_config_list_item "$key" "$value" "$file"
            else
                config_warn "Unknown configuration key '$key' in $file (ignored)"
            fi
            ;;
    esac
}

# env: entries are handed to parse_env_assignment as KEY=<raw value> later so
# quoting, comments, ~ and $VAR expansion behave exactly like in .env files.
apply_config_env_item() {
    local key="$1" raw="$2" file="$3"
    local quote prefix idx

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        config_warn "Skipping invalid environment variable name in $file: $key"
        return 0
    fi

    raw=$(trim_whitespace "$raw")
    # Drop a trailing comment after a closing quote ("value" # comment)
    if [[ "$raw" == \"* || "$raw" == \'* ]]; then
        quote="${raw:0:1}"
        prefix="${raw%"$quote"*}"
        idx=${#prefix}
        if [[ $idx -gt 0 ]]; then
            raw="${raw:0:idx+1}"
        fi
    fi

    ENV_VARS+=("$key=$raw")
}

# Flow sequence: key: [a, b, c]. Items may not contain commas.
parse_yaml_flow_list() {
    local key="$1" raw="$2" file="$3"
    local body item value
    local -a items=()

    body=$(strip_yaml_comment "$raw")
    body="${body#\[}"
    body="${body%\]}"
    IFS=',' read -r -a items <<< "$body"
    for item in "${items[@]}"; do
        if parse_yaml_scalar "$item" value; then
            apply_config_list_item "$key" "$value" "$file"
        fi
    done
}

# Flow mapping for env: {KEY: value, OTHER: value}. Values may not contain commas.
parse_yaml_flow_map() {
    local raw="$1" file="$2" lineno="$3"
    local body entry
    local -a entries=()

    body=$(strip_yaml_comment "$raw")
    body="${body#\{}"
    body="${body%\}}"
    IFS=',' read -r -a entries <<< "$body"
    for entry in "${entries[@]}"; do
        entry=$(trim_whitespace "$entry")
        [[ -z "$entry" ]] && continue
        if [[ "$entry" =~ ^([A-Za-z_][A-Za-z0-9_]*):([[:space:]]+(.*))?$ ]]; then
            apply_config_env_item "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "$file"
        else
            config_warn "$file:$lineno: invalid env entry '$entry' (ignored)"
        fi
    done
}

# Parse one config.yaml file. Supported subset of YAML:
#   key: value            scalars (quoted or unquoted, true/false booleans)
#   key:                  followed by indented "- item" lines (block list)
#   key: [a, b]           flow list (list keys only)
#   env:                  followed by indented "KEY: value" lines (mapping)
#   env: {KEY: value}     flow mapping
#   # comments, ---/... document markers, CRLF line endings, tab indentation
# Anything else produces a warning and is ignored.
parse_config_file() {
    local file="$1"
    local raw_line line lineno=0
    local state=none current_key=""
    local indent key rhs rhs_trimmed item value

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        ((lineno++)) || true
        line="${raw_line%$'\r'}"
        if [[ $lineno -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
        fi

        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == "---"* || "$line" == "..." ]] && continue

        # Block list item
        if [[ "$line" =~ ^[[:space:]]*-([[:space:]]+(.*))?$ ]]; then
            item="${BASH_REMATCH[2]}"
            if [[ ( "$state" == pending || "$state" == list ) && -n "$current_key" ]]; then
                if [[ "$state" == pending ]] && ! is_config_list_key "$current_key"; then
                    config_warn "$file:$lineno: key '$current_key' does not accept a list (ignored)"
                    state=skip
                    continue
                fi
                state=list
                if parse_yaml_scalar "$item" value; then
                    apply_config_list_item "$current_key" "$value" "$file"
                fi
            elif [[ "$state" != skip ]]; then
                config_warn "$file:$lineno: list item outside of a list (ignored)"
            fi
            continue
        fi

        # key: value / key:
        if [[ "$line" =~ ^([[:space:]]*)([A-Za-z_][A-Za-z0-9_]*):([[:space:]]+(.*))?$ ]]; then
            indent="${#BASH_REMATCH[1]}"
            key="${BASH_REMATCH[2]}"
            rhs="${BASH_REMATCH[4]}"

            if [[ $indent -gt 0 ]]; then
                if [[ "$state" == pending && "$current_key" == env ]]; then
                    state=env
                fi
                case "$state" in
                    env)
                        apply_config_env_item "$key" "$rhs" "$file"
                        continue
                        ;;
                    pending)
                        config_warn "$file:$lineno: nested mapping under '$current_key' is not supported (ignored)"
                        state=skip
                        continue
                        ;;
                    skip)
                        continue
                        ;;
                    *)
                        config_warn "$file:$lineno: unexpected indentation, treating '$key' as a top-level key"
                        ;;
                esac
            fi

            # Removed keys are fatal: silently dropping blacklist_files would
            # expose files the user meant to hide
            case "$key" in
                whitelist_files|blacklist_files|env_files)
                    config_error "$file:$lineno: '$key' is no longer supported, move the entries of the referenced files into the '${key%_files}' key"
                    ;;
            esac

            # A previous key without a value and without a block is null
            if [[ "$state" == pending ]]; then
                apply_config_scalar "$current_key" "" "$file" true
            fi
            state=none
            current_key=""

            rhs_trimmed=$(trim_whitespace "$rhs")
            if [[ -z "$rhs_trimmed" || "$rhs_trimmed" == "#"* ]]; then
                # Header of a block list / mapping, or a null value
                current_key="$key"
                state=pending
                continue
            fi

            if is_config_list_key "$key" && [[ "$rhs_trimmed" == "["* && "$(strip_yaml_comment "$rhs_trimmed")" == *"]" ]]; then
                parse_yaml_flow_list "$key" "$rhs_trimmed" "$file"
            elif [[ "$key" == env && "$rhs_trimmed" == "{"* ]]; then
                parse_yaml_flow_map "$rhs_trimmed" "$file" "$lineno"
            elif [[ "$rhs_trimmed" == [\|\>\&\*\{]* ]]; then
                config_warn "$file:$lineno: unsupported YAML syntax for '$key' (ignored)"
            elif parse_yaml_scalar "$rhs" value; then
                apply_config_scalar "$key" "$value" "$file" false
            else
                apply_config_scalar "$key" "" "$file" true
            fi
            continue
        fi

        config_warn "$file:$lineno: unsupported syntax (ignored): $(trim_whitespace "$line")"
    done < "$file"

    if [[ "$state" == pending ]]; then
        apply_config_scalar "$current_key" "" "$file" true
    fi
}

# Project-level files are controlled by the repository (or, for the main
# checkout's config.local.yaml, by whoever works in it)
is_project_config_file() {
    [[ "$1" == "$PROJECT_CONFIG_DIR/"* || ( -n "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" && "$1" == "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" ) ]]
}

load_config_files() {
    local file
    for file in "$DEFAULT_CONFIG_FILE" "$DEFAULT_CONFIG_LOCAL_FILE" \
        "$PROJECT_CONFIG_FILE" "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" "$PROJECT_CONFIG_LOCAL_FILE"; do
        [[ -n "$file" ]] || continue
        [[ -f "$file" ]] || continue
        CONFIG_FILES_LOADED+=("$file")
        parse_config_file "$file"
    done
}

# --- Profiles -----------------------------------------------------------------
#
# A profile holds the agent's configuration, credentials and memory. Profile
# data lives in $PROFILES_DIR/<name>/home and mirrors the home directory layout
# (e.g. .claude/, .claude.json), so any agent's dotfiles map 1:1 into $HOME.
# The reserved profile "default" uses the host's own home directory.

validate_profile_name() {
    if [[ ! "$PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo -e "${RED}Error: Invalid profile name '$PROFILE'${NC}" >&2
        echo "Profile names may contain letters, digits, '.', '_' and '-', and must start with a letter or digit" >&2
        exit 1
    fi
}

resolve_profile_home() {
    if [[ "$PROFILE" == "default" ]]; then
        PROFILE_HOME="$HOME"
    else
        PROFILE_HOME="$PROFILES_DIR/$PROFILE/home"
    fi
}

list_profiles() {
    local dir name marker
    echo "default (host configuration)"
    [[ -d "$PROFILES_DIR" ]] || return 0
    for dir in "$PROFILES_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        name="${dir%/}"
        name="${name##*/}"
        marker=""
        if [[ -f "$dir/home/.claude/.credentials.json" ]]; then
            marker=" (claude: logged in)"
        fi
        echo "$name$marker"
    done
}

# Create the profile directory on first use. The store is 0700 because it
# holds credentials of every profile.
prepare_profile_home() {
    [[ "$PROFILE" != "default" ]] || return 0
    [[ -d "$PROFILES_DIR/$PROFILE" ]] && return 0

    if [[ ! -d "$PROFILES_DIR" ]]; then
        mkdir -p "$PROFILES_DIR"
        chmod 700 "$PROFILES_DIR"
    fi
    mkdir -p "$PROFILE_HOME"
    log_info "${YELLOW}Created new profile '$PROFILE' at $PROFILES_DIR/$PROFILE (empty configuration, log in inside the sandbox)${NC}"
}

# Bind a directory from the profile home into the sandbox at the same relative
# location under $HOME, creating it on first use.
bind_profile_dir() {
    local rel="$1"
    local src="$PROFILE_HOME/$rel"

    if [[ -d "$src" ]]; then
        log_info "${GREEN}✓${NC} Mounted ~/$rel (read-write)"
    else
        mkdir -p "$src"
        log_info "${YELLOW}✓${NC} Created and mounted ~/$rel (read-write)"
    fi
    BWRAP_ARGS+=(--bind "$src" "$HOME/$rel")
}

# Bind a file from the profile home into the sandbox, creating it with the
# given initial content on first use.
bind_profile_file() {
    local rel="$1"
    local initial="${2-}"
    local src="$PROFILE_HOME/$rel"

    if [[ -f "$src" ]]; then
        log_info "${GREEN}✓${NC} Mounted ~/$rel (read-write)"
    else
        mkdir -p "$(dirname "$src")"
        printf '%s' "$initial" > "$src"
        log_info "${YELLOW}✓${NC} Created and mounted ~/$rel (read-write)"
    fi
    BWRAP_ARGS+=(--bind "$src" "$HOME/$rel")
}

# Check whether the installed bubblewrap can mount overlay filesystems
bwrap_supports_overlay() {
    "$BWRAP_BIN" --help 2>&1 | grep -q -- '--overlay-src'
}

# Share a host directory with every profile: mount ~/<rel> as an overlay with
# the host's directory as the read-only lower layer and the profile's own
# directory as the writable upper layer. The profile sees the host's entries
# plus its own; whatever it adds, changes or deletes stays in the profile and
# the host directory is never modified. Must be called after the profile bind
# that contains <rel>. The overlay workdir lives next to the profile home (same
# filesystem as the upper layer) and is not visible inside the sandbox.
# Usage: overlay_shared_profile_dir <rel> <work-name>
overlay_shared_profile_dir() {
    local rel="$1"
    local work_name="$2"
    local lower upper work

    [[ "$PROFILE" != "default" ]] || return 0
    [[ "$SHARE_SKILLS" = true ]] || return 0
    [[ -d "$HOME/$rel" ]] || return 0

    if ! bwrap_supports_overlay; then
        log_info "${YELLOW}⚠${NC} Not sharing host ~/$rel with profile '$PROFILE' (bubblewrap lacks overlay support)"
        return 0
    fi

    # The host directory may itself be a symlink (e.g. into a dotfiles repository)
    lower=$(readlink -f "$HOME/$rel")
    upper="$PROFILE_HOME/$rel"
    work="$PROFILES_DIR/$PROFILE/overlay-work/$work_name"
    mkdir -p "$upper" "$work"

    BWRAP_ARGS+=(--overlay-src "$lower")
    BWRAP_ARGS+=(--overlay "$upper" "$work" "$HOME/$rel")
    log_info "${GREEN}✓${NC} Mounted ~/$rel (host skills shared, profile skills on top)"
}

# --- Git worktrees ------------------------------------------------------------
#
# Git worktrees and submodule checkouts have a ".git" file instead of a
# directory. It points at a gitdir inside the main repository, usually outside
# the working directory (git worktree add ../x, T3 Code's ~/.t3/worktrees/...),
# and a worktree gitdir in turn names the shared "commondir" that holds objects
# and refs. mount_git_linked_dirs binds that directory read-write at its own
# path, otherwise every git command inside the sandbox fails. This exposes
# nothing a normal checkout does not already expose through its own .git
# (hooks, config). The main checkout's config.local.yaml is loaded as well when
# the worktree has none (git-ignored files are not copied into a worktree).
# Only verified worktree layouts are followed, see resolve_git_worktree.
GIT_LINKED_DIRS=()
GIT_WORKTREE_COMMON_DIR=""
GIT_WORKTREE_WARNINGS=()

# Usage: resolve_git_link_path <base-dir> <path>; relative paths resolve against base-dir
resolve_git_link_path() {
    local target="$2"
    [[ "$target" = /* ]] || target="$1/$target"
    realpath -m -- "$target"
}

# Usage: path_is_within <path> <dir>
path_is_within() {
    [[ "$1" = "$2" || "$1" = "$2"/* ]]
}

# Sets GIT_WORKTREE_COMMON_DIR when $WORKING_DIR is a verified worktree;
# otherwise collects the reason in GIT_WORKTREE_WARNINGS (logged later by
# mount_git_linked_dirs, once --quiet is known).
resolve_git_worktree() {
    local git_file="$WORKING_DIR/.git"
    [[ -f "$git_file" ]] || return 0
    # The .git file is writable by the agent, so nothing read from it (or from a
    # directory it names) may decide what gets mounted on its own. The link is
    # followed only when the target has the layout git writes for a worktree of
    # THIS working tree: <common>/worktrees/<name> whose gitdir back-link points
    # at $WORKING_DIR/.git. An agent cannot forge that back-link in a directory
    # it has no access to. The common dir is derived from the path, never from
    # the editable commondir file.
    local line gitdir common_dir back_link
    IFS= read -r line < "$git_file" || true
    if [[ "$line" != gitdir:* ]]; then
        GIT_WORKTREE_WARNINGS+=("Warning: $git_file is not a gitdir link; git may not work inside the sandbox")
        return 0
    fi
    gitdir=$(resolve_git_link_path "$WORKING_DIR" "$(trim_whitespace "${line#gitdir:}")")
    if [[ ! -d "$gitdir" ]]; then
        GIT_WORKTREE_WARNINGS+=("Warning: gitdir $gitdir referenced by $git_file does not exist; not following the .git link")
        return 0
    fi
    if [[ "$(basename "$(dirname "$gitdir")")" != worktrees ]]; then
        GIT_WORKTREE_WARNINGS+=("Warning: $gitdir is not a git worktree directory (<repo>/.git/worktrees/<name>); not following the .git link."
            "         Separate git dirs and submodules are not followed automatically; add the git dir with --whitelist-path-rw or the whitelist: key of your user config instead")
        return 0
    fi
    common_dir=$(dirname "$(dirname "$gitdir")")
    if [[ ! -f "$gitdir/gitdir" ]]; then
        GIT_WORKTREE_WARNINGS+=("Warning: $gitdir/gitdir is missing; not following the .git link (run 'git worktree repair')")
        return 0
    fi
    IFS= read -r line < "$gitdir/gitdir" || true
    back_link=$(resolve_git_link_path "$gitdir" "$(trim_whitespace "$line")")
    if [[ "$back_link" != "$(realpath -m -- "$git_file")" ]]; then
        GIT_WORKTREE_WARNINGS+=("Warning: $gitdir belongs to the worktree $back_link, not to $git_file; not following the .git link (run 'git worktree repair' if the worktree was moved)")
        return 0
    fi
    if [[ ! -f "$gitdir/commondir" ]]; then
        GIT_WORKTREE_WARNINGS+=("Warning: $gitdir/commondir is missing; not following the .git link")
        return 0
    fi
    IFS= read -r line < "$gitdir/commondir" || true
    if [[ "$(resolve_git_link_path "$gitdir" "$(trim_whitespace "$line")")" != "$common_dir" ]]; then
        GIT_WORKTREE_WARNINGS+=("Warning: $gitdir/commondir does not point at $common_dir; not following the .git link")
        return 0
    fi
    if [[ ! -f "$common_dir/HEAD" || ! -d "$common_dir/objects" ]]; then
        GIT_WORKTREE_WARNINGS+=("Warning: $common_dir is not a git directory; not following the .git link")
        return 0
    fi
    GIT_WORKTREE_COMMON_DIR="$common_dir"

    # The main checkout of a non-bare repository is the parent of its .git
    # directory. The agent in this worktree cannot write there (only the git
    # directory itself is mounted), so its personal config.local.yaml is as
    # trustworthy as the worktree's own would be.
    local main_checkout
    [[ "$(basename "$common_dir")" == .git ]] || return 0
    main_checkout=$(dirname "$common_dir")
    [[ "$main_checkout" != "$WORKING_DIR" ]] || return 0
    if [[ ! -f "$PROJECT_CONFIG_LOCAL_FILE" && -f "$main_checkout/.ai-agent-sandbox/config.local.yaml" ]]; then
        MAIN_CHECKOUT_CONFIG_LOCAL_FILE="$main_checkout/.ai-agent-sandbox/config.local.yaml"
    fi
}

# --- Legacy configuration files (deprecated) -----------------------------------
#
# whitelist.txt, blacklist.txt, .env and .env.local predate config.yaml. Each
# level (user, project) uses them only when it has no config.yaml or
# config.local.yaml; either way their presence is reported as deprecated.
# User-level files are offered for migration on an interactive start;
# project-level files only with --migrate-project-conf, because they are
# usually shared through git and every team member would need a sandbox
# version that reads config.yaml first.

# Print a deprecation warning for the given legacy files. Always shown, even
# with --quiet, so that the migration is not missed.
warn_legacy_files() {
    local level="$1"
    local yaml_file="$2"
    local ignored="$3"
    local hint="$4"
    shift 4
    [[ $# -gt 0 ]] || return 0

    local file
    if [[ "$ignored" = true ]]; then
        echo -e "${RED}Warning: Ignoring deprecated $level configuration files because a config.yaml/config.local.yaml exists:${NC}" >&2
    else
        echo -e "${RED}Warning: Using deprecated $level configuration files:${NC}" >&2
    fi
    for file in "$@"; do
        echo -e "${RED}  $file${NC}" >&2
    done
    if [[ "$ignored" = false ]]; then
        echo -e "${RED}  Support for whitelist.txt, blacklist.txt and .env files will be dropped in a future release.${NC}" >&2
    fi
    echo -e "${RED}  Move their entries into $yaml_file (keys: whitelist, blacklist, env), $hint.${NC}" >&2
}

# Format a whitelist/blacklist entry as a YAML list item, single-quoted when
# it would not survive as a plain scalar
yaml_list_item() {
    local item="$1"
    if [[ "$item" =~ ^[A-Za-z0-9_./\$~] && "$item" != "~" \
        && "$item" != null && "$item" != Null && "$item" != NULL \
        && "$item" != *"#"* && "$item" != *": "* && "$item" != *":" \
        && "$item" != *"'"* && "$item" != *'"'* ]]; then
        printf -- '- %s\n' "$item"
    else
        printf -- "- '%s'\n" "${item//\'/\'\'}"
    fi
}

# Print the entries of a legacy whitelist/blacklist file as YAML list items,
# read the same way the files are read at startup
legacy_list_lines() {
    local file="$1" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # As at startup, everything after # is a comment
        line=$(trim_whitespace "${line%%#*}")
        line="${line%$'\r'}"
        [[ -n "$line" ]] || continue
        yaml_list_item "$line"
    done < "$file"
}

# Print the entries of a legacy .env file as "KEY: value" lines. The value is
# copied verbatim: env values in config.yaml follow the same quoting and
# expansion rules as .env files.
legacy_env_lines() {
    local file="$1" line key value lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        line=$(trim_whitespace "${line%$'\r'}")
        [[ -z "$line" || "$line" == "#"* ]] && continue
        if [[ "$line" == export[[:space:]]* ]]; then
            line=$(trim_whitespace "${line#export}")
        fi
        key=$(trim_whitespace "${line%%=*}")
        if [[ "$line" != *=* || ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo -e "${YELLOW}  $file:$lineno: not a KEY=VALUE entry (skipped)${NC}" >&2
            continue
        fi
        value=$(trim_whitespace "${line#*=}")
        [[ -n "$value" ]] || value='""'
        printf '%s: %s\n' "$key" "$value"
    done < "$file"
}

# Merge the lines of $lines_file into the top-level block $key of a YAML file
# and print the result. mode=list merges "- item" lines, mode=map "KEY: value"
# lines. A missing block is appended; entries already present are skipped and
# reported on stderr. Exits with 2 when the key uses the inline form.
yaml_merge_block() {
    local file="$1" key="$2" mode="$3" lines_file="$4"
    awk -v key="$key" -v mode="$mode" -v lines_file="$lines_file" '
        function entry_id(e) {
            if (mode == "map") {
                sub(/[ \t]*:.*/, "", e)
            } else {
                sub(/^-[ \t]*/, "", e)
                sub(/[ \t]+#.*$/, "", e)
            }
            return e
        }
        BEGIN {
            n = 0
            while ((getline l < lines_file) > 0) {
                new[++n] = l
            }
            close(lines_file)
        }
        { line[NR] = $0 }
        END {
            h = 0
            for (i = 1; i <= NR; i++) {
                if (line[i] ~ ("^" key ":([ \t].*)?$")) {
                    h = i
                    break
                }
            }
            if (h) {
                rhs = substr(line[h], length(key) + 2)
                sub(/^[ \t]+/, "", rhs)
                if (rhs ~ /^#/) {
                    rhs = ""
                }
                sub(/[ \t]+#.*$/, "", rhs)
                sub(/[ \t]+$/, "", rhs)
                if (rhs == "[]" || rhs == "{}") {
                    line[h] = key ":"
                } else if (rhs != "") {
                    exit 2
                }
            }

            last = h
            indent = "  "
            found_indent = 0
            if (h) {
                for (i = h + 1; i <= NR; i++) {
                    if (line[i] ~ /^[ \t]*$/ || line[i] ~ /^[ \t]*#/) {
                        continue
                    }
                    if (line[i] ~ /^[ \t]/ || (mode == "list" && line[i] ~ /^-/)) {
                        last = i
                        if (!found_indent) {
                            match(line[i], /^[ \t]*/)
                            indent = substr(line[i], 1, RLENGTH)
                            found_indent = 1
                        }
                        e = line[i]
                        sub(/^[ \t]*/, "", e)
                        existing[entry_id(e)] = 1
                        continue
                    }
                    break
                }
            }

            m = 0
            for (j = 1; j <= n; j++) {
                id = entry_id(new[j])
                if (id in existing) {
                    print new[j] > "/dev/stderr"
                    continue
                }
                existing[id] = 1
                add[++m] = new[j]
            }

            for (i = 1; i <= NR; i++) {
                print line[i]
                if (h && i == last) {
                    for (j = 1; j <= m; j++) {
                        print indent add[j]
                    }
                }
            }
            if (!h && m > 0) {
                if (NR > 0 && line[NR] !~ /^[ \t]*$/) {
                    print ""
                }
                print key ":"
                for (j = 1; j <= m; j++) {
                    print indent add[j]
                }
            }
        }
    ' "$file"
}

# Merge one legacy file into a staged config file. Records the source in
# MIGRATED_SOURCES and the staged file in MIGRATED_TARGETS.
migrate_legacy_file() {
    local src="$1" key="$2" mode="$3" staged="$4" target="$5" tmp_dir="$6"
    local rc=0 skipped

    [[ -f "$src" ]] || return 0

    if [[ "$mode" == list ]]; then
        legacy_list_lines "$src" > "$tmp_dir/lines" || rc=$?
    else
        legacy_env_lines "$src" > "$tmp_dir/lines" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        echo -e "${RED}Error: Could not read $src${NC}" >&2
        return 1
    fi
    yaml_merge_block "$staged" "$key" "$mode" "$tmp_dir/lines" \
        > "$tmp_dir/merged" 2> "$tmp_dir/skipped" || rc=$?
    if [[ $rc -ne 0 ]]; then
        if [[ $rc -eq 2 ]]; then
            echo -e "${RED}Error: '$key' in $target uses the inline form ([...] or {...}); change it to a block list and migrate again${NC}" >&2
        else
            echo -e "${RED}Error: Could not merge $src into $target${NC}" >&2
        fi
        return 1
    fi
    mv "$tmp_dir/merged" "$staged"

    echo -e "${GREEN}✓${NC} $src → $target ($key)" >&2
    while IFS= read -r skipped; do
        if [[ "$mode" == map ]]; then
            skipped="${skipped%%:*}"
        fi
        echo -e "${YELLOW}  already in $target, kept the existing entry: $skipped${NC}" >&2
    done < "$tmp_dir/skipped"

    MIGRATED_SOURCES+=("$src")
    MIGRATED_TARGETS["$staged"]="$target"
}

# Migrate the legacy files of one level into its config.yaml (whitelist,
# blacklist, .env) and config.local.yaml (.env.local). Nothing is written
# unless every file merges; the old files are then renamed to *.migrated.
migrate_legacy_config() {
    local config_file="$1" config_local_file="$2"
    local whitelist_file="$3" blacklist_file="$4" env_file="$5" env_local_file="$6"
    local tmp_dir staged target src backup ok=true

    MIGRATED_SOURCES=()
    declare -gA MIGRATED_TARGETS=()

    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-agent-sandbox-migrate.XXXXXX")
    for staged in "$tmp_dir/config.yaml" "$tmp_dir/config.local.yaml"; do
        target="$config_file"
        [[ "$staged" == */config.local.yaml ]] && target="$config_local_file"
        if [[ -f "$target" ]]; then
            cp "$target" "$staged"
        else
            echo "# AI Agent Sandbox configuration, see config-example.yaml for all keys" > "$staged"
        fi
    done

    migrate_legacy_file "$whitelist_file" whitelist list "$tmp_dir/config.yaml" "$config_file" "$tmp_dir" \
        && migrate_legacy_file "$blacklist_file" blacklist list "$tmp_dir/config.yaml" "$config_file" "$tmp_dir" \
        && migrate_legacy_file "$env_file" env map "$tmp_dir/config.yaml" "$config_file" "$tmp_dir" \
        && migrate_legacy_file "$env_local_file" env map "$tmp_dir/config.local.yaml" "$config_local_file" "$tmp_dir" \
        || ok=false

    if [[ "$ok" = true ]]; then
        for staged in "${!MIGRATED_TARGETS[@]}"; do
            target="${MIGRATED_TARGETS[$staged]}"
            mkdir -p "$(dirname "$target")"
            # Overwrite in place to keep the permissions of an existing file
            cat "$staged" > "$target"
        done
        for src in "${MIGRATED_SOURCES[@]}"; do
            backup="$src.migrated"
            [[ -e "$backup" ]] && backup="$src.migrated.$(date +%Y%m%d%H%M%S)"
            mv "$src" "$backup"
            echo -e "${GREEN}✓${NC} Renamed $src → $backup" >&2
        done
    else
        echo -e "${RED}Migration aborted, no files were changed${NC}" >&2
    fi
    rm -rf "$tmp_dir"
    [[ "$ok" = true ]]
}

# Explain what the migration does, shared by the prompt and --migrate-project-conf
explain_legacy_migration() {
    local config_file="$1" config_local_file="$2" has_yaml="$3"
    shift 3

    local file
    echo -e "${RED}Deprecated configuration files found:${NC}" >&2
    for file in "$@"; do
        echo "  $file" >&2
    done
    cat >&2 << EOMIGRATE
whitelist.txt, blacklist.txt, .env and .env.local are replaced by config.yaml;
support for them will be dropped in a future release. The migration moves
  whitelist.txt → 'whitelist:' in $config_file
  blacklist.txt → 'blacklist:' in $config_file
  .env          → 'env:'       in $config_file
  .env.local    → 'env:'       in $config_local_file
Existing entries are kept, the old files are renamed to *.migrated.
EOMIGRATE
    if [[ "$has_yaml" = true ]]; then
        echo -e "${RED}Note: these files are currently IGNORED because a config.yaml/config.local.yaml exists.${NC}" >&2
        echo -e "${RED}Migrating them makes their entries active again.${NC}" >&2
    fi
}

# Check Docker availability when enabled
validate_docker() {
    if [[ "$ENABLE_DOCKER" != true ]]; then
        return 0
    fi

    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Error: Docker is not installed or not in PATH${NC}" >&2
        echo "Install Docker from: https://docs.docker.com/engine/install/" >&2
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo -e "${RED}Error: Docker daemon is not running or not accessible${NC}" >&2
        echo "Ensure Docker service is started and you have permissions" >&2
        exit 1
    fi

    if ! docker compose version &>/dev/null; then
        log_info "${YELLOW}Warning: Docker Compose is not available on the host Docker client; install the Compose plugin for 'docker compose' support${NC}"
    fi

    if ! docker image inspect "$SOCKET_PROXY_IMAGE" &>/dev/null; then
        log_info "${YELLOW}Socket proxy image not found, pulling: $SOCKET_PROXY_IMAGE${NC}"
        if ! docker pull "$SOCKET_PROXY_IMAGE" >/dev/null; then
            echo -e "${RED}Error: Failed to pull socket proxy image${NC}" >&2
            exit 1
        fi
    fi
}

# Check GPG agent forwarding prerequisites and prepare a public-key-only GnuPG
# home directory for the sandbox. Secret keys stay on the host: the sandbox only
# talks to the host gpg-agent through its restricted "extra" socket.
validate_gpg_agent() {
    if [[ "$ENABLE_GPG_AGENT" != true ]]; then
        return 0
    fi

    local tool
    for tool in gpg gpgconf; do
        if ! command -v "$tool" &>/dev/null; then
            echo -e "${RED}Error: $tool is not installed or not in PATH (required for --gpg-agent)${NC}" >&2
            exit 1
        fi
    done

    GPG_HOST_EXTRA_SOCKET="$(gpgconf --list-dirs agent-extra-socket 2>/dev/null || true)"
    if [[ -z "$GPG_HOST_EXTRA_SOCKET" ]]; then
        echo -e "${RED}Error: Could not determine the gpg-agent extra socket path${NC}" >&2
        exit 1
    fi

    # Launch the host agent if it is not running yet so its sockets exist
    if [[ ! -S "$GPG_HOST_EXTRA_SOCKET" ]]; then
        gpgconf --launch gpg-agent 2>/dev/null || true
    fi
    if [[ ! -S "$GPG_HOST_EXTRA_SOCKET" ]]; then
        echo -e "${RED}Error: gpg-agent extra socket not found: $GPG_HOST_EXTRA_SOCKET${NC}" >&2
        echo "Start the agent on the host with: gpgconf --launch gpg-agent" >&2
        exit 1
    fi

    local gpg_format
    gpg_format="$(git -C "$WORKING_DIR" config --get gpg.format 2>/dev/null || true)"
    if [[ -n "$gpg_format" && "$gpg_format" != "openpgp" ]]; then
        log_info "${YELLOW}Warning: git gpg.format is '$gpg_format'; --gpg-agent only forwards OpenPGP signing${NC}"
    fi

    # Public keys to expose: the configured git signing key, or otherwise every
    # key the host has secret material (or a smartcard stub) for
    local -a key_ids=()
    local signing_key
    signing_key="$(git -C "$WORKING_DIR" config --get user.signingkey 2>/dev/null || true)"
    if [[ -n "$signing_key" ]]; then
        key_ids+=("$signing_key")
    else
        local fpr
        while IFS= read -r fpr; do
            [[ -n "$fpr" ]] && key_ids+=("$fpr")
        done < <(gpg --batch --with-colons --list-secret-keys 2>/dev/null \
            | awk -F: '$1 == "sec" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }')
    fi
    if [[ ${#key_ids[@]} -eq 0 ]]; then
        echo -e "${RED}Error: No GPG signing key found on the host${NC}" >&2
        echo "Set git user.signingkey or make sure 'gpg --list-secret-keys' shows a key" >&2
        exit 1
    fi

    GPG_SANDBOX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ai-agent-sandbox-gnupg.XXXXXX")"
    chmod 700 "$GPG_SANDBOX_HOME"

    # Export public keys only into the temporary keyring
    if ! gpg --batch --export -- "${key_ids[@]}" 2>/dev/null \
        | gpg --batch --quiet --no-autostart --homedir "$GPG_SANDBOX_HOME" --import 2>/dev/null; then
        echo -e "${RED}Error: Failed to export public key(s): ${key_ids[*]}${NC}" >&2
        exit 1
    fi

    local -a exported_fprs=()
    mapfile -t exported_fprs < <(gpg --batch --no-autostart --homedir "$GPG_SANDBOX_HOME" --with-colons --list-keys 2>/dev/null \
        | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }')
    if [[ ${#exported_fprs[@]} -eq 0 ]]; then
        echo -e "${RED}Error: No public key exported for: ${key_ids[*]}${NC}" >&2
        exit 1
    fi

    # Carry over the host's ownertrust so signature verification inside the
    # sandbox does not warn about untrusted keys
    gpg --batch --export-ownertrust 2>/dev/null \
        | grep -F -f <(printf '%s:\n' "${exported_fprs[@]}") \
        | gpg --batch --quiet --no-autostart --homedir "$GPG_SANDBOX_HOME" --import-ownertrust 2>/dev/null || true

    local has_secret=false
    for fpr in "${exported_fprs[@]}"; do
        if gpg --batch --list-secret-keys -- "$fpr" &>/dev/null; then
            has_secret=true
            break
        fi
    done
    if [[ "$has_secret" != true ]]; then
        log_info "${YELLOW}Warning: The host has no secret key (or smartcard stub) for ${exported_fprs[*]}; signing may fail${NC}"
    fi
}

# Forward the host gpg-agent into the sandbox
mount_gpg_agent() {
    [[ "$ENABLE_GPG_AGENT" = true ]] || return 0

    local runtime_dir
    runtime_dir="/run/user/$(id -u)"

    # gpg only uses /run/user/<uid>/gnupg when both directories are owned by
    # the user with mode 0700; otherwise it falls back to ~/.gnupg
    BWRAP_ARGS+=(--perms 0700 --dir "$runtime_dir")
    BWRAP_ARGS+=(--perms 0700 --dir "$runtime_dir/gnupg")
    # The host's restricted extra socket becomes the sandbox's regular agent socket
    BWRAP_ARGS+=(--ro-bind "$GPG_HOST_EXTRA_SOCKET" "$runtime_dir/gnupg/S.gpg-agent")
    # Public-key-only keyring prepared by validate_gpg_agent
    BWRAP_ARGS+=(--bind "$GPG_SANDBOX_HOME" "$HOME/.gnupg")
    BWRAP_ARGS+=(--unsetenv GNUPGHOME)

    log_info "${GREEN}✓${NC} Forwarded gpg-agent: $GPG_HOST_EXTRA_SOCKET -> $runtime_dir/gnupg/S.gpg-agent"
    log_info "${GREEN}✓${NC} Mounted public-key-only keyring at ~/.gnupg"
}

mount_docker_compose_plugins() {
    [[ "$ENABLE_DOCKER" = true ]] || return 0

    local mounted=false
    local plugin_dir

    for plugin_dir in "${DOCKER_COMPOSE_PLUGIN_DIRS[@]}"; do
        if [[ -x "$plugin_dir/docker-compose" ]]; then
            if [[ "$plugin_dir" == "$HOME/"* ]]; then
                BWRAP_ARGS+=(--dir "$HOME/.docker")
            fi
            BWRAP_ARGS+=(--ro-bind "$plugin_dir" "$plugin_dir")
            log_info "${GREEN}✓${NC} Mounted Docker CLI plugins: $plugin_dir"
            mounted=true
        fi
    done

    if [[ "$mounted" = false ]]; then
        log_info "${YELLOW}Warning: No Docker Compose CLI plugin found in standard locations; 'docker compose' may be unavailable in the sandbox${NC}"
    fi
}

detect_venv() {
    if [[ "$ENABLE_VENV" != true ]]; then
        return 0
    fi

    if [[ -z "${VIRTUAL_ENV:-}" ]]; then
        log_info "${YELLOW}Warning: --venv specified, but no active virtual environment was detected (continuing without venv)${NC}"
        ENABLE_VENV=false
        return 0
    fi

    VENV_PATH="${VIRTUAL_ENV/#\~/$HOME}"
    VENV_PATH="${VENV_PATH//\$HOME/$HOME}"
    if [[ "$VENV_PATH" != /* ]]; then
        VENV_PATH="$WORKING_DIR/$VENV_PATH"
    fi

    while [[ "$VENV_PATH" == */ && "$VENV_PATH" != "/" ]]; do
        VENV_PATH="${VENV_PATH%/}"
    done

    if [[ ! -d "$VENV_PATH" ]]; then
        log_info "${YELLOW}Warning: active virtual environment does not exist: $VENV_PATH (continuing without venv)${NC}"
        VENV_PATH=""
        ENABLE_VENV=false
        return 0
    fi

    VENV_BIN_DIR="$VENV_PATH/bin"
    if [[ ! -d "$VENV_BIN_DIR" ]]; then
        log_info "${YELLOW}Warning: active virtual environment has no bin directory: $VENV_BIN_DIR (continuing without venv)${NC}"
        VENV_PATH=""
        VENV_BIN_DIR=""
        ENABLE_VENV=false
    fi
}

collect_allowed_mount_paths() {
    local paths="$WORKING_DIR"

    # Add read-write whitelist paths
    for path in "${WHITELIST_PATHS_RW[@]}"; do
        path="${path/#\~/$HOME}"
        path="${path//\$HOME/$HOME}"
        if [[ "$path" != /* ]]; then
            path="$WORKING_DIR/$path"
        fi
        if [[ -e "$path" ]]; then
            paths="$paths,$path"
        fi
    done

    # Add read-write bind mounts from bubblewrap args. This intentionally uses
    # the bind SOURCE (host path), not the destination: the Docker daemon
    # resolves paths on the host, so allowing the destination would let a
    # non-default profile mount the host's own ~/.claude (default profile).
    local i=0
    while [[ $i -lt ${#BWRAP_ARGS[@]} ]]; do
        if [[ "${BWRAP_ARGS[$i]}" == "--bind" ]]; then
            local bind_path="${BWRAP_ARGS[$((i+1))]}"
            if [[ -e "$bind_path" ]]; then
                paths="$paths,$bind_path"
            fi
        fi
        ((i++))
    done

    echo "$paths" | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//'
}

start_socket_proxy() {
    PROXY_CONTAINER_NAME="ai-agent-sandbox-proxy-$$"
    PROXY_SOCKET_DIR="$WORKING_DIR/.docker-proxy"
    PROXY_SOCKET_PATH="$PROXY_SOCKET_DIR/docker.sock"
    local docker_group_gid=""
    local proxy_group_args=()

    log_info "\n${GREEN}=== Starting Docker Socket Proxy ===${NC}"

    local allowed_paths
    allowed_paths=$(collect_allowed_mount_paths)

    log_info "Allowed bind mount paths:"
    echo "$allowed_paths" | tr ',' '\n' | while IFS= read -r p; do
        [[ -n "$p" ]] && log_info "  ${GREEN}✓${NC} $p"
    done

    mkdir -p "$PROXY_SOCKET_DIR"
    chmod 0777 "$PROXY_SOCKET_DIR" 2>/dev/null || true
    rm -f "$PROXY_SOCKET_PATH"

    docker_group_gid=$(getent group docker | cut -d: -f3 2>/dev/null || true)

    if [[ -n "$docker_group_gid" ]]; then
        proxy_group_args=(--group-add "$docker_group_gid")
    fi

    log_info "\nStarting proxy container: $PROXY_CONTAINER_NAME"
    if ! docker run -d \
        --name "$PROXY_CONTAINER_NAME" \
        --rm \
        --user 0:0 \
        "${proxy_group_args[@]}" \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v "$PROXY_SOCKET_DIR:/proxy" \
        "$SOCKET_PROXY_IMAGE" \
        -proxysocketendpoint=/proxy/docker.sock \
        -proxysocketendpointfilemode=0666 \
        -allowbindmountfrom="$allowed_paths" \
        -allowGET='/v1\..{1,2}/.*' \
        -allowHEAD='/_ping' \
        -allowPOST='/v1\..{1,2}/.*' \
        -allowPUT='/v1\..{1,2}/.*' \
        -allowDELETE='/v1\..{1,2}/(containers|images|networks|volumes)/.*' \
        >/dev/null; then
        echo -e "${RED}Error: Failed to start socket proxy container${NC}" >&2
        exit 1
    fi

    local timeout=20
    while [[ ! -S "$PROXY_SOCKET_PATH" ]] && [[ $timeout -gt 0 ]]; do
        sleep 0.5
        ((timeout--))
    done

    if [[ ! -S "$PROXY_SOCKET_PATH" ]]; then
        echo -e "${RED}Error: Socket proxy failed to create socket${NC}" >&2
        if docker ps -a --format '{{.Names}}' | grep -q "^${PROXY_CONTAINER_NAME}$"; then
            echo -e "${YELLOW}Socket proxy logs:${NC}" >&2
            docker logs "$PROXY_CONTAINER_NAME" >&2 || true
        fi
        cleanup_socket_proxy
        exit 1
    fi

    if ! DOCKER_HOST="unix://$PROXY_SOCKET_PATH" docker version &>/dev/null; then
        echo -e "${YELLOW}Warning: Socket proxy may not be fully functional${NC}" >&2
    fi

    log_info "${GREEN}✓${NC} Socket proxy started successfully"
    log_info "${GREEN}✓${NC} Proxy socket: $PROXY_SOCKET_PATH"
    log_info "${GREEN}========================================${NC}\n"
}

cleanup_socket_proxy() {
    if [[ -n "${PROXY_CONTAINER_NAME:-}" ]]; then
        local container_name="$PROXY_CONTAINER_NAME"
        PROXY_CONTAINER_NAME=""
        log_info "${YELLOW}Cleaning up socket proxy: $container_name${NC}"
        docker stop "$container_name" 2>/dev/null || true
        docker rm -f "$container_name" 2>/dev/null || true
    fi
    if [[ -n "${PROXY_SOCKET_PATH:-}" ]] && [[ -e "$PROXY_SOCKET_PATH" ]]; then
        rm -f "$PROXY_SOCKET_PATH" 2>/dev/null || true
    fi
    if [[ -n "${PROXY_SOCKET_DIR:-}" ]] && [[ -d "$PROXY_SOCKET_DIR" ]]; then
        rmdir "$PROXY_SOCKET_DIR" 2>/dev/null || true
    fi
}

# --- Network isolation ---------------------------------------------------------
#
# In isolated mode bwrap keeps a new network namespace and pasta (package passt)
# attaches user-mode networking to it: outbound connections are proxied through
# host sockets, ports bound inside are published on the host (-t auto), nothing
# else gets in. The host's loopback is not mapped (--no-map-gw) and only the TCP
# ports listed in NETWORK_HOST_PORTS are forwarded into the namespace (-T).
# Private address ranges and the host's own subnets are blocked with
# unreachable routes installed from the host before the agent starts (bwrap
# blocks on --block-fd until the setup is done).
#
# Changing routes needs CAP_NET_ADMIN in the user namespace that owns the
# network namespace. bwrap's own --unshare-user puts the sandboxed process (and
# everything reachable via /proc/<pid>/ns/user) into a nested user namespace
# below that owner, so nothing could be entered from the host. The sandbox
# therefore uses two user namespaces created by the script (create_user_namespace,
# kept alive by fds): bwrap --userns joins the first one, which then owns the
# network namespace and can be entered from the host via /proc/self/fd/<fd>
# (joining a user namespace one created grants all capabilities in it), and
# --userns2 moves the sandboxed process into the second, nested one, where it
# has no capabilities over the network namespace and cannot alter the routes.

# Decides the effective mode and checks the tools it needs. Fatal when the user
# asked for isolation explicitly; a silent default falls back to the host
# network with a warning so an upgrade does not break existing setups.
resolve_network_mode() {
    local missing=()
    if [[ -z "$NETWORK_MODE" ]]; then
        NETWORK_MODE="$NETWORK_MODE_DEFAULT"
        NETWORK_MODE_SOURCE="default"
    fi
    dedupe_array NETWORK_HOST_PORTS
    dedupe_array NETWORK_ALLOW_HOSTS
    [[ "$NETWORK_MODE" = isolated ]] || return 0

    PASTA_BIN=$(command -v pasta 2>/dev/null || true)
    NSENTER_BIN=$(command -v nsenter 2>/dev/null || true)
    IP_BIN=$(command -v ip 2>/dev/null || true)
    UNSHARE_BIN=$(command -v unshare 2>/dev/null || true)
    if [[ -z "$UNSHARE_BIN" ]]; then
        missing+=("unshare (package util-linux)")
    elif ! "$UNSHARE_BIN" --help 2>&1 | grep -q -- --map-user; then
        missing+=("unshare with --map-user (util-linux >= 2.38)")
    fi
    [[ -n "$PASTA_BIN" ]] || missing+=("pasta (package passt)")
    if [[ -z "$NSENTER_BIN" ]]; then
        missing+=("nsenter (package util-linux)")
    elif ! "$NSENTER_BIN" --help 2>&1 | grep -q -- --keep-caps; then
        missing+=("nsenter with --keep-caps (util-linux >= 2.37)")
    fi
    [[ -n "$IP_BIN" ]] || missing+=("ip (package iproute2)")
    [[ ${#missing[@]} -eq 0 ]] && return 0

    if [[ "$NETWORK_MODE_SOURCE" = default ]]; then
        NETWORK_MODE="host"
        NETWORK_MODE_SOURCE="fallback"
        echo -e "${YELLOW}⚠ Network isolation needs ${missing[*]}; falling back to the host network. Install the tools or set 'network: host' to silence this warning${NC}" >&2
    else
        echo -e "${RED}Error: network isolation (from $NETWORK_MODE_SOURCE) needs ${missing[*]}${NC}" >&2
        echo "Install them (Debian/Ubuntu: sudo apt install passt; Fedora: sudo dnf install passt) or run with --network host" >&2
        exit 1
    fi
}

# Host nameservers of one address family from /etc/resolv.conf (4 or 6)
host_nameservers() {
    local family="$1" line
    [[ -f /etc/resolv.conf ]] || return 0
    while read -r line; do
        [[ "$line" =~ ^[[:space:]]*nameserver[[:space:]]+([^[:space:]#]+) ]] || continue
        case "$family" in
            4) [[ "${BASH_REMATCH[1]}" == *.* && "${BASH_REMATCH[1]}" != *:* ]] && echo "${BASH_REMATCH[1]}" ;;
            6) [[ "${BASH_REMATCH[1]}" == *:* ]] && echo "${BASH_REMATCH[1]}" ;;
        esac
    done < /etc/resolv.conf
}

# Creates the temporary directory (FIFOs for bwrap, generated resolv.conf) and
# appends the resolv.conf bind. Inside the namespace the host's nameservers are
# unreachable (a resolver on 127.0.0.53 would be the sandbox's own loopback),
# so DNS goes to addresses pasta forwards to the host's first resolver.
prepare_isolated_network() {
    local line
    NETWORK_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-agent-sandbox-net.XXXXXX")"
    NETWORK_DNS_FORWARD_ARGS=()
    {
        if [[ -f /etc/resolv.conf ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" =~ ^[[:space:]]*nameserver([[:space:]]|$) ]] && continue
                printf '%s\n' "$line"
            done < /etc/resolv.conf
        fi
        if [[ -n "$(host_nameservers 4)" ]]; then
            printf 'nameserver %s\n' "$NETWORK_DNS4"
            NETWORK_DNS_FORWARD_ARGS+=(--dns-forward "$NETWORK_DNS4")
        fi
        if [[ -n "$(host_nameservers 6)" ]]; then
            printf 'nameserver %s\n' "$NETWORK_DNS6"
            NETWORK_DNS_FORWARD_ARGS+=(--dns-forward "$NETWORK_DNS6")
        fi
    } > "$NETWORK_TMP_DIR/resolv.conf"
    if [[ ${#NETWORK_DNS_FORWARD_ARGS[@]} -eq 0 ]]; then
        log_info "${YELLOW}⚠${NC} No nameserver in /etc/resolv.conf, DNS will not work inside the sandbox"
    fi
    BWRAP_ARGS+=(--ro-bind "$NETWORK_TMP_DIR/resolv.conf" /etc/resolv.conf)
}

# Creates a user namespace mapping our uid and gid to themselves and stores an
# fd to it in the variable named by $1; with a parent fd in $2 the namespace is
# nested in that one (its maps must be written from inside the parent, which
# unshare does when run through nsenter). The fd alone keeps the namespace
# alive, the helper process is only needed until the fd is open.
create_user_namespace() {
    local out_ref="$1" parent_fd="${2:-}" holder own parent current fd i
    local -a cmd=()
    own=$(readlink /proc/self/ns/user)
    parent="$own"
    if [[ -n "$parent_fd" ]]; then
        cmd=("$NSENTER_BIN" --preserve-credentials --user="/proc/self/fd/$parent_fd" --)
        parent=$(readlink "/proc/self/fd/$parent_fd")
    fi
    "${cmd[@]}" "$UNSHARE_BIN" --user --map-user="$(id -u)" --map-group="$(id -g)" -- sleep 60 &
    holder=$!
    # The holder starts in our namespace, moves to the parent (nsenter) and
    # ends up in the new one, where unshare writes both maps before it execs
    # sleep. It must not be killed before that. procfs files report size 0,
    # so the maps have to be read, not stat'ed.
    for ((i = 0; i < 100; i++)); do
        current=$(readlink "/proc/$holder/ns/user" 2>/dev/null)
        if [[ -n "$current" && "$current" != "$own" && "$current" != "$parent" ]] \
            && [[ -n "$(cat "/proc/$holder/uid_map" 2>/dev/null)" ]] \
            && [[ -n "$(cat "/proc/$holder/gid_map" 2>/dev/null)" ]]; then
            break
        fi
        sleep 0.05
    done
    if ! exec {fd}<"/proc/$holder/ns/user"; then
        kill "$holder" 2>/dev/null || true
        return 1
    fi
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    printf -v "$out_ref" '%s' "$fd"
}

# Runs a command inside the sandbox's network namespace with the capabilities
# of the user namespace that owns it (ours, see above). --keep-caps (util-linux
# >= 2.37) carries them over the exec as ambient capabilities; a non-root uid
# would otherwise lose them when running ip.
ns_exec() {
    "$NSENTER_BIN" --preserve-credentials --keep-caps \
        --user="/proc/self/fd/$SANDBOX_USERNS_FD" --net="/proc/$SANDBOX_CHILD_PID/ns/net" -- "$@"
}

# Usage: ns_route <4|6> <args...>; `replace` tolerates duplicates (a host
# subnet that is also a blocked range). Errors are reported with the command.
ns_route() {
    local family="$1" output
    shift
    if ! output=$(ns_exec "$IP_BIN" "-$family" route replace "$@" 2>&1); then
        echo -e "${YELLOW}⚠ ip -$family route replace $*: ${output:-failed}${NC}" >&2
        return 1
    fi
}

# Subnets directly attached to the host, which pasta would otherwise let the
# namespace reach: IPv4 on-link routes and IPv6 prefixes without a gateway.
# Very short prefixes (a VPN's 0.0.0.0/1 dev tun0) are not LANs and stay open.
host_onlink_subnets() {
    local family="$1" prefix rest min_len=8
    [[ "$family" = 6 ]] && min_len=16
    "$IP_BIN" "-$family" route show 2>/dev/null | while read -r prefix rest; do
        [[ "$prefix" == */* ]] || continue
        [[ " $rest " == *" via "* ]] && continue
        (( ${prefix##*/} >= min_len )) || continue
        case "$prefix" in
            fe80::/64|::1/128|127.*) continue ;;
        esac
        echo "$prefix"
    done
}

# Resolved addresses (with optional /prefix) of one allow_hosts entry
resolve_allow_host() {
    local entry="$1"
    if [[ "$entry" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ || "$entry" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*(/[0-9]{1,3})?$ ]]; then
        echo "$entry"
        return 0
    fi
    getent ahosts "$entry" 2>/dev/null | awk '{print $1}' | sort -u
}

# Attaches pasta to the network namespace of bwrap's child and installs the routes.
# Requires SANDBOX_CHILD_PID; returns non-zero when the sandbox must not start.
setup_isolated_network() {
    local -a pasta_args=() blocked4=() blocked6=()
    local -a addrs=()
    local host_ports="none" subnet gw6="" entry addr line failed=false

    if [[ ${#NETWORK_HOST_PORTS[@]} -gt 0 ]]; then
        host_ports=$(IFS=,; echo "${NETWORK_HOST_PORTS[*]}")
    fi
    pasta_args=(
        --quiet --config-net --no-map-gw
        --ns-ifname "$NETWORK_IFNAME"
        --address "$NETWORK_NS_ADDR4" --gateway "$NETWORK_GW4"
        "${NETWORK_DNS_FORWARD_ARGS[@]}"
        --tcp-ports auto --udp-ports auto
        --tcp-ns "$host_ports" --udp-ns none
    )
    # pasta closes every inherited fd before it opens the namespace paths, so the
    # user namespace fd has to be addressed through this shell's /proc entry
    pasta_args+=(--userns "/proc/$BASHPID/fd/$SANDBOX_USERNS_FD" --netns "/proc/$SANDBOX_CHILD_PID/ns/net")
    if ! "$PASTA_BIN" "${pasta_args[@]}"; then
        echo -e "${RED}Error: pasta could not set up the sandbox network${NC}" >&2
        return 1
    fi

    # pasta sets ping_group_range to "0 2147483647" in the namespace so ping can
    # use ICMP datagram sockets, but a group id must be mapped in the user
    # namespace to be accepted and ours maps only our own gid: set that one.
    # Without it ping fails with "Operation not permitted" (CAP_NET_RAW is
    # dropped in the sandbox) although TCP/UDP work.
    if ! ns_exec sh -c 'echo "$1 $1" > /proc/sys/net/ipv4/ping_group_range' sh "$(id -g)" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Could not enable ICMP sockets in the sandbox network; ping will not work${NC}" >&2
    fi

    # Blocked ranges: the private ranges plus every subnet the host is on
    mapfile -t blocked4 < <(printf '%s\n' "${NETWORK_BLOCKED_V4[@]}"; host_onlink_subnets 4)
    mapfile -t blocked6 < <(printf '%s\n' "${NETWORK_BLOCKED_V6[@]}"; host_onlink_subnets 6)
    for subnet in "${blocked4[@]}"; do
        ns_route 4 unreachable "$subnet" metric "$NETWORK_BLOCK_METRIC" || failed=true
    done
    for subnet in "${blocked6[@]}"; do
        ns_route 6 unreachable "$subnet" metric "$NETWORK_BLOCK_METRIC" || failed=true
    done
    if [[ "$failed" = true ]]; then
        echo -e "${RED}Error: could not install the network block routes in the sandbox${NC}" >&2
        return 1
    fi

    # pasta copies the host's IPv6 gateway; keep it reachable when it sits in a
    # blocked prefix (a link-local gateway is covered by the on-link fe80::/64)
    line=$(ns_exec "$IP_BIN" -6 route show default 2>/dev/null | head -n 1 || true)
    if [[ "$line" =~ \ via\ ([^\ ]+) ]]; then
        gw6="${BASH_REMATCH[1]}"
        [[ "$gw6" == fe80:* ]] || ns_route 6 "$gw6/128" dev "$NETWORK_IFNAME" metric "$NETWORK_ALLOW_METRIC" || true
    fi

    for entry in "${NETWORK_ALLOW_HOSTS[@]}"; do
        mapfile -t addrs < <(resolve_allow_host "$entry")
        if [[ ${#addrs[@]} -eq 0 ]]; then
            echo -e "${YELLOW}⚠ Cannot resolve allowed host '$entry', skipping${NC}" >&2
            continue
        fi
        for addr in "${addrs[@]}"; do
            if [[ "$addr" == *:* ]]; then
                if [[ -z "$gw6" ]]; then
                    echo -e "${YELLOW}⚠ No IPv6 gateway in the sandbox, cannot allow $addr ($entry)${NC}" >&2
                    continue
                fi
                ns_route 6 "$addr" via "$gw6" dev "$NETWORK_IFNAME" metric "$NETWORK_ALLOW_METRIC" \
                    || echo -e "${YELLOW}⚠ Could not allow $addr ($entry)${NC}" >&2
            else
                ns_route 4 "$addr" via "$NETWORK_GW4" dev "$NETWORK_IFNAME" metric "$NETWORK_ALLOW_METRIC" \
                    || echo -e "${YELLOW}⚠ Could not allow $addr ($entry)${NC}" >&2
            fi
        done
    done
    return 0
}

cleanup_network() {
    if [[ -n "${NETWORK_TMP_DIR:-}" ]] && [[ -d "$NETWORK_TMP_DIR" ]]; then
        rm -rf "$NETWORK_TMP_DIR" 2>/dev/null || true
    fi
}

cleanup_gpg_agent() {
    if [[ -n "${GPG_SANDBOX_HOME:-}" ]] && [[ -d "$GPG_SANDBOX_HOME" ]]; then
        rm -rf "$GPG_SANDBOX_HOME" 2>/dev/null || true
    fi
}

cleanup_sandbox() {
    cleanup_socket_proxy
    cleanup_gpg_agent
    cleanup_network
}

# Shells conventionally report signal termination as 128 + signal number.
SIGHUP_SIGNAL=1
SIGTERM_SIGNAL=15
SIGHUP_EXIT_STATUS=$((128 + SIGHUP_SIGNAL))
SIGTERM_EXIT_STATUS=$((128 + SIGTERM_SIGNAL))

# bwrap runs as a background job that the script waits for (see run_in_sandbox):
# bash defers traps while a foreground child runs, so a SIGTERM from an
# orchestrator (T3 Code, a supervisor) would otherwise be ignored until the agent
# exits by itself. The signal is forwarded to bwrap, which terminates the
# sandbox, then the EXIT trap cleans up.
SANDBOX_PID=""

# Usage: forward_signal_and_exit <signal> <exit-status>
forward_signal_and_exit() {
    if [[ -n "$SANDBOX_PID" ]]; then
        kill -s "$1" "$SANDBOX_PID" 2>/dev/null || true
    fi
    exit "$2"
}

# Usage: run_in_sandbox <command> [args...]; returns the command's exit status
run_in_sandbox() {
    local status=0 line
    local -a bwrap_extra=()
    if [[ "$NETWORK_MODE" = isolated ]]; then
        # Two user namespaces of our own (see "Network isolation"): --userns can
        # not be combined with --unshare-user, so --unshare-all is spelled out
        if ! create_user_namespace SANDBOX_USERNS_FD \
            || ! create_user_namespace SANDBOX_USERNS2_FD "$SANDBOX_USERNS_FD"; then
            echo -e "${RED}Error: could not create the user namespaces for the sandbox network${NC}" >&2
            return 1
        fi
        local -a unshared_args=()
        local arg
        for arg in "${BWRAP_ARGS[@]}"; do
            if [[ "$arg" = --unshare-all ]]; then
                unshared_args+=(--unshare-ipc --unshare-pid --unshare-net --unshare-uts --unshare-cgroup-try)
            else
                unshared_args+=("$arg")
            fi
        done
        BWRAP_ARGS=("${unshared_args[@]}")
        # bwrap reports the child pid on --info-fd and holds the command until
        # --block-fd becomes readable: pasta and the routes go in between
        mkfifo "$NETWORK_TMP_DIR/info" "$NETWORK_TMP_DIR/block"
        exec {NETWORK_INFO_FD}<>"$NETWORK_TMP_DIR/info" {NETWORK_BLOCK_FD}<>"$NETWORK_TMP_DIR/block"
        bwrap_extra=(--userns "$SANDBOX_USERNS_FD" --userns2 "$SANDBOX_USERNS2_FD"
            --info-fd "$NETWORK_INFO_FD" --block-fd "$NETWORK_BLOCK_FD")
    fi
    # Explicit stdin redirect: a background job in a non-interactive shell
    # would otherwise read from /dev/null (agents driven over stdin need it).
    # Job control stays off so bwrap remains in our process group, which
    # orchestrators signal as a whole.
    "$BWRAP_BIN" "${BWRAP_ARGS[@]}" "${bwrap_extra[@]}" -- "$@" <&0 &
    SANDBOX_PID=$!
    if [[ "$NETWORK_MODE" = isolated ]]; then
        SANDBOX_CHILD_PID=""
        while read -r -t 15 -u "$NETWORK_INFO_FD" line; do
            if [[ "$line" =~ \"child-pid\":[[:space:]]*([0-9]+) ]]; then
                SANDBOX_CHILD_PID="${BASH_REMATCH[1]}"
                break
            fi
        done
        if [[ -z "$SANDBOX_CHILD_PID" ]] || ! setup_isolated_network; then
            [[ -n "$SANDBOX_CHILD_PID" ]] || echo -e "${RED}Error: bwrap did not report the sandbox pid${NC}" >&2
            # bwrap ignores SIGTERM while its child still waits on --block-fd,
            # so the blocked child is killed directly and bwrap follows; when
            # the pid was never reported the child is looked up as bwrap's child
            [[ -n "$SANDBOX_CHILD_PID" ]] || SANDBOX_CHILD_PID=$(pgrep -P "$SANDBOX_PID" 2>/dev/null | head -n 1 || true)
            kill -s TERM "$SANDBOX_PID" 2>/dev/null || true
            if [[ -n "$SANDBOX_CHILD_PID" ]]; then
                kill -s KILL "$SANDBOX_CHILD_PID" 2>/dev/null || true
            fi
            SANDBOX_CHILD_PID=""
            wait "$SANDBOX_PID" 2>/dev/null || true
            SANDBOX_PID=""
            exec {NETWORK_INFO_FD}>&- {NETWORK_BLOCK_FD}>&- {SANDBOX_USERNS_FD}>&- {SANDBOX_USERNS2_FD}>&-
            return 1
        fi
        echo go >&"$NETWORK_BLOCK_FD"
        exec {NETWORK_INFO_FD}>&- {NETWORK_BLOCK_FD}>&- {SANDBOX_USERNS_FD}>&- {SANDBOX_USERNS2_FD}>&-
    fi
    while :; do
        status=0
        wait "$SANDBOX_PID" || status=$?
        # wait returns >128 when a trap interrupted it; keep waiting while bwrap lives
        if (( status > 128 )) && kill -0 "$SANDBOX_PID" 2>/dev/null; then
            continue
        fi
        break
    done
    SANDBOX_PID=""
    return "$status"
}

# Strip inline comments and trim whitespace from a line
# Usage: result=$(strip_inline_comment "$line")
strip_inline_comment() {
    local line="$1"
    # Strip inline comments (anything after #)
    line="${line%%#*}"
    # Trim leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    # Trim trailing whitespace
    line="${line%"${line##*[![:space:]]}"}"
    echo "$line"
}

# Expand $VAR / ${VAR} references and tildes in an environment value.
# Variables resolve against values already set for the sandbox first, then the
# host environment, and expand to empty when undefined. \$ produces a literal $.
expand_env_value() {
    local input="$1"
    local output=""
    local var_name

    # Tilde expansion: at the start of the value and after each colon in
    # PATH-style lists.
    input="${input/#\~/$HOME}"
    input="${input//:\~\//:$HOME/}"

    while [[ -n "$input" ]]; do
        if [[ "$input" == \\\$* ]]; then
            output+='$'
            input="${input:2}"
        elif [[ "$input" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\} || "$input" =~ ^\$([A-Za-z_][A-Za-z0-9_]*) ]]; then
            var_name="${BASH_REMATCH[1]}"
            if [[ -v "SANDBOX_ENV[$var_name]" ]]; then
                output+="${SANDBOX_ENV[$var_name]}"
            else
                output+="$(printenv "$var_name" || true)"
            fi
            input="${input:${#BASH_REMATCH[0]}}"
        else
            output+="${input:0:1}"
            input="${input:1}"
        fi
    done

    printf '%s\n' "$output"
}

parse_env_assignment() {
    local line="$1"
    local key_ref="$2"
    local value_ref="$3"
    local env_key
    local env_value
    local single_quoted=false

    line=$(trim_whitespace "$line")
    [[ -z "$line" || "$line" =~ ^# ]] && return 1

    if [[ "$line" == export[[:space:]]* ]]; then
        line="${line#export}"
        line=$(trim_whitespace "$line")
    fi

    [[ "$line" == *=* ]] || return 1

    env_key=$(trim_whitespace "${line%%=*}")
    env_value="${line#*=}"
    env_value=$(trim_whitespace "$env_value")

    if [[ ! "$env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        log_info "${YELLOW}⚠${NC} Skipping invalid environment variable name: $env_key"
        return 1
    fi

    if [[ "$env_value" == \"*\" && "$env_value" == *\" ]]; then
        env_value="${env_value#\"}"
        env_value="${env_value%\"}"
    elif [[ "$env_value" == \'*\' && "$env_value" == *\' ]]; then
        env_value="${env_value#\'}"
        env_value="${env_value%\'}"
        single_quoted=true
    else
        env_value="${env_value%%[[:space:]]#*}"
        env_value=$(trim_whitespace "$env_value")
    fi

    # Single-quoted values are literal; everything else gets variable and
    # tilde expansion so entries like PATH="~/bin:$PATH" work.
    if [[ "$single_quoted" != true ]]; then
        env_value=$(expand_env_value "$env_value")
    fi

    printf -v "$key_ref" '%s' "$env_key"
    printf -v "$value_ref" '%s' "$env_value"
}

# Set an environment variable inside the sandbox and remember its value so
# later env entries can reference it (e.g. PATH="~/bin:$PATH").
sandbox_setenv() {
    local key="$1"
    local value="$2"
    BWRAP_ARGS+=(--setenv "$key" "$value")
    SANDBOX_ENV[$key]="$value"
}

set_sandbox_env() {
    local assignment="$1"
    local source_label="$2"
    local key=""
    local value=""

    if ! parse_env_assignment "$assignment" key value; then
        log_info "${YELLOW}⚠${NC} Skipping invalid environment entry from $source_label"
        return 0
    fi

    sandbox_setenv "$key" "$value"
    log_info "${GREEN}✓${NC} Environment variable: $key"
}

# Parse override prefix in whitelist entries
# Usage: read -r override path < <(parse_whitelist_override "$line")
parse_whitelist_override() {
    local line="$1"
    local override="false"
    if [[ "$line" == "!"* ]]; then
        override="true"
        line="${line#\!}"
        line="${line#"${line%%[![:space:]]*}"}"
    fi
    echo "$override" "$line"
}

is_covered_by_blacklisted_dir() {
    local path="$1"
    local blocked_dir
    for blocked_dir in "${BLACKLISTED_DIRS[@]}"; do
        if [[ "$path" == "$blocked_dir" || "$path" == "$blocked_dir/"* ]]; then
            return 0
        fi
    done
    return 1
}

remember_blacklisted_dir() {
    local dir="$1"
    local blocked_dir
    for blocked_dir in "${BLACKLISTED_DIRS[@]}"; do
        [[ "$blocked_dir" == "$dir" ]] && return
    done
    BLACKLISTED_DIRS+=("$dir")
}

remember_blacklist_search_root() {
    local root="$1"
    local existing_root

    [[ -d "$root" ]] || return

    for existing_root in "${BLACKLIST_SEARCH_ROOTS[@]}"; do
        [[ "$existing_root" == "$root" ]] && return
    done

    BLACKLIST_SEARCH_ROOTS+=("$root")
}

display_path() {
    local path="$1"

    if [[ "$path" == "$WORKING_DIR" ]]; then
        echo "."
    elif [[ "$path" == "$WORKING_DIR/"* ]]; then
        echo "${path#$WORKING_DIR/}"
    else
        echo "$path"
    fi
}

# Find matches for a pattern (supports ant-style ** patterns)
# Usage: find_matches <base_dir> <pattern>
# Returns: list of matching absolute paths (one per line)
find_matches() {
    local base_dir="$1"
    local pattern="$2"
    local find_args=()

    # If no pattern, just return the base_dir itself (literal path)
    if [[ -z "$pattern" ]]; then
        echo "$base_dir"
        return
    fi

    # Convert ant-style pattern to find command
    if [[ "$pattern" == *"**"* ]]; then
        # Ant-style recursive pattern
        if [[ "$pattern" =~ ^\*\*/([^/]+)$ ]]; then
            # Pattern like **/wallet.dat - match the filename at any depth
            local filename="${BASH_REMATCH[1]}"
            find_args=(-name "$filename")
        else
            # Pattern with directory components like **/dir/file or
            # src/**/test/**/*.java. Each **/ matches zero or more directories,
            # but find -path has no alternation, so expand every **/ into both
            # "*/" (one or more levels, * crosses /) and "" (zero levels), then
            # OR all variants in a single find expression.
            local -a path_patterns=("$pattern")
            local expanding=true
            local p
            while [[ "$expanding" == true ]]; do
                expanding=false
                local -a expanded=()
                for p in "${path_patterns[@]}"; do
                    if [[ "$p" == *"**/"* ]]; then
                        expanded+=("${p/\*\*\//*/}" "${p/\*\*\//}")
                        expanding=true
                    else
                        expanded+=("$p")
                    fi
                done
                path_patterns=("${expanded[@]}")
            done

            find_args=(\()
            local first=true
            for p in "${path_patterns[@]}"; do
                [[ "$first" == true ]] || find_args+=(-o)
                first=false
                # Convert any remaining ** (trailing, not followed by /) to *
                find_args+=(-path "$base_dir/${p//\*\*/\*}")
            done
            find_args+=(\))
        fi
    else
        # Simple glob pattern - limit to single level
        if [[ "$pattern" == */* ]]; then
            # Pattern has directory components like dir/*.txt
            local path_pattern="$pattern"
            find_args=(-path "$base_dir/$path_pattern")
        else
            # Simple filename pattern like *.txt
            find_args=(-maxdepth 1 -name "$pattern")
        fi
    fi

    # Execute find and return results
    find "$base_dir" "${find_args[@]}" 2>/dev/null
}

# Whitelist a single path (with glob and ant-style pattern support)
# Usage: whitelist_path <path> <bind_mode>
# bind_mode: "ro" for read-only, "rw" for read-write
# Supports both absolute paths and relative paths (relative to working directory)
whitelist_path() {
    local path="$1"
    local bind_mode="$2"
    local target_array_name="${3:-BWRAP_ARGS}"
    local label="${4:-Whitelisted}"
    local -n target_array="$target_array_name"
    local is_relative_path=false

    # Expand environment variables without eval (faster)
    path="${path/#\~/$HOME}"
    path="${path//\$HOME/$HOME}"

    # Convert relative paths to absolute (relative to working directory)
    if [[ "$path" != /* ]]; then
        is_relative_path=true
        path="$WORKING_DIR/$path"
    fi

    # Use find for all paths (patterns and literals)
    local base_dir="/"
    local pattern="$path"

    # Extract base directory if path starts with absolute path
    if [[ "$path" == /* ]]; then
        # For patterns, find the first directory component before any wildcard
        if [[ "$path" =~ [\*\?\[]|\*\* ]]; then
            # Always use the parent directory of the pattern, not the prefix itself
            local prefix="${path%%[*?[]*}"
            # Strip to the last directory separator to get the parent
            local parent="${prefix%/*}"
            if [[ -d "$parent" && -n "$parent" ]]; then
                base_dir="$parent"
                pattern="${path#$parent}"
                pattern="${pattern#/}"
            fi
        else
            # For literal paths, use the path itself as base_dir
            base_dir="$path"
            pattern=""
        fi
    fi

    local match_count=0
    while IFS= read -r match; do
        if [[ -e "$match" ]]; then
            if [[ "$is_relative_path" = true ]]; then
                if [[ -d "$match" ]]; then
                    remember_blacklist_search_root "$match"
                else
                    remember_blacklist_search_root "$(dirname "$match")"
                fi
            fi

            if [[ "$bind_mode" = "rw" ]]; then
                target_array+=(--bind "$match" "$match")
                log_info "${GREEN}✓${NC} ${label} (rw): $match"
            else
                target_array+=(--ro-bind "$match" "$match")
                log_info "${GREEN}✓${NC} ${label}: $match"
            fi
            ((match_count++)) || true
        fi
    done < <(find_matches "$base_dir" "$pattern")

    if [[ $match_count -eq 0 ]]; then
        log_info "${YELLOW}⚠${NC} No matches for pattern: $path"
    fi
}

# Blacklist a single pattern (relative to working directory, supports ant-style patterns)
# Usage: blacklist_pattern <pattern>
blacklist_pattern() {
    local pattern="$1"
    local search_root

    # Normalize trailing slashes so entries like ".trees/" match correctly.
    while [[ "$pattern" == */ && "$pattern" != "/" ]]; do
        pattern="${pattern%/}"
    done

    # Use find to match patterns (supports ant-style **)
    local match_count=0
    local skip_count=0
    for search_root in "${BLACKLIST_SEARCH_ROOTS[@]}"; do
        while IFS= read -r match; do
            if [[ -e "$match" || -L "$match" ]]; then
                if [[ -L "$match" ]]; then
                    local match_display
                    match_display=$(display_path "$match")
                    local target
                    target=$(readlink -f "$match" 2>/dev/null || true)

                    # bubblewrap cannot safely mount over symlink paths. If a symlink
                    # resolves inside one of the exposed blacklist search roots,
                    # blacklist the resolved target instead. Otherwise skip it.
                    if [[ -n "$target" && -e "$target" ]]; then
                        local target_root=""
                        local candidate_root
                        for candidate_root in "${BLACKLIST_SEARCH_ROOTS[@]}"; do
                            if [[ "$target" == "$candidate_root" || "$target" == "$candidate_root/"* ]]; then
                                target_root="$candidate_root"
                                break
                            fi
                        done

                        if [[ -n "$target_root" ]]; then
                            if is_covered_by_blacklisted_dir "$target"; then
                                log_info "${YELLOW}⚠${NC} Skipping blacklist for ${match_display} (already covered by blacklisted parent dir)"
                                ((skip_count++)) || true
                                continue
                            fi

                            local target_display
                            target_display=$(display_path "$target")
                            if [[ -d "$target" ]]; then
                                BWRAP_ARGS+=(--tmpfs "$target")
                                remember_blacklisted_dir "$target"
                                log_info "${RED}✗${NC} Blacklisted (symlink->dir target): ${match_display} -> ${target_display}"
                            else
                                BWRAP_ARGS+=(--ro-bind /dev/null "$target")
                                log_info "${RED}✗${NC} Blacklisted (symlink->file target): ${match_display} -> ${target_display}"
                            fi
                        else
                            log_info "${YELLOW}⚠${NC} Skipping symlink blacklist for ${match_display} (target is outside accessible roots or unresolved)"
                        fi
                    else
                        log_info "${YELLOW}⚠${NC} Skipping symlink blacklist for ${match_display} (target is outside accessible roots or unresolved)"
                    fi
                elif [[ -d "$match" ]]; then
                    if is_covered_by_blacklisted_dir "$match"; then
                        log_info "${YELLOW}⚠${NC} Skipping blacklist for $(display_path "$match") (already covered by blacklisted parent dir)"
                        ((skip_count++)) || true
                        continue
                    fi

                    # Hide directories with tmpfs overlay
                    BWRAP_ARGS+=(--tmpfs "$match")
                    remember_blacklisted_dir "$match"
                    log_info "${RED}✗${NC} Blacklisted (dir): $(display_path "$match")"
                else
                    if is_covered_by_blacklisted_dir "$match"; then
                        log_info "${YELLOW}⚠${NC} Skipping blacklist for $(display_path "$match") (already covered by blacklisted parent dir)"
                        ((skip_count++)) || true
                        continue
                    fi

                    # Hide files by binding /dev/null over them
                    BWRAP_ARGS+=(--ro-bind /dev/null "$match")
                    log_info "${RED}✗${NC} Blacklisted (file): $(display_path "$match")"
                fi
                ((match_count++)) || true
            fi
        done < <(find_matches "$search_root" "$pattern")
    done

    if [[ $match_count -eq 0 && $skip_count -eq 0 ]]; then
        log_info "${YELLOW}⚠${NC} No matches for pattern: $pattern"
    fi
}

# Check whether a path is already visible inside the sandbox via an existing
# bind mount in BWRAP_ARGS (the destination equals the path or is a parent of it)
# Usage: is_path_bound <path>
is_path_bound() {
    local path="$1"
    local i=0
    local dest
    while [[ $i -lt ${#BWRAP_ARGS[@]} ]]; do
        if [[ "${BWRAP_ARGS[$i]}" == "--bind" || "${BWRAP_ARGS[$i]}" == "--ro-bind" ]]; then
            dest="${BWRAP_ARGS[$((i+2))]}"
            if [[ "$path" == "$dest" || "$path" == "$dest/"* ]]; then
                return 0
            fi
        fi
        ((i++)) || true
    done
    return 1
}

# Warn about earlier bind mounts whose destination is at or under <dest>: they
# become invisible once <dest> is mounted over them (e.g. a whitelisted
# ~/.claude/agents hidden by the profile's ~/.claude mount)
warn_shadowed_binds() {
    local dest="$1"
    local i=0
    local existing
    while [[ $i -lt ${#BWRAP_ARGS[@]} ]]; do
        if [[ "${BWRAP_ARGS[$i]}" == "--bind" || "${BWRAP_ARGS[$i]}" == "--ro-bind" ]]; then
            existing="${BWRAP_ARGS[$((i+2))]}"
            if [[ "$existing" == "$dest" || "$existing" == "$dest/"* ]]; then
                log_info "${YELLOW}⚠${NC} Mount at $existing is shadowed by the profile mount at $dest"
            fi
        fi
        ((i++)) || true
    done
}

# Process one whitelist entry (a line from a whitelist file or a config
# `whitelist:` item): handles the ! override prefix and the :rw suffix
process_whitelist_entry() {
    local line="$1"
    local override bind_mode

    read -r override line < <(parse_whitelist_override "$line")
    [[ -z "$line" ]] && return 0

    bind_mode="ro"
    if [[ "$line" =~ :rw$ ]]; then
        bind_mode="rw"
        line="${line%:rw}"
    fi

    if [[ "$override" = "true" ]]; then
        whitelist_path "$line" "$bind_mode" "WHITELIST_OVERRIDE_ARGS" "Whitelisted (override)"
    else
        whitelist_path "$line" "$bind_mode" "BWRAP_ARGS" "Whitelisted"
    fi
}

# Mount .ai-agent-sandbox/ read-only so the agent cannot rewrite the sandbox
# configuration (profile, whitelist, env) that will apply to the next run.
# Blacklist mounts are added later and nest on top of this bind.
protect_project_config_dir() {
    [[ "$PROTECT_PROJECT_CONFIG" = true ]] || return 0
    [[ -d "$PROJECT_CONFIG_DIR" ]] || return 0
    BWRAP_ARGS+=(--ro-bind "$PROJECT_CONFIG_DIR" "$PROJECT_CONFIG_DIR")
    log_info "${GREEN}✓${NC} Mounted .ai-agent-sandbox/ read-only (sandbox configuration protected)"
}

# Mount the main repository's git directory into a verified git worktree, see
# resolve_git_worktree (run before the config files are loaded)
mount_git_linked_dirs() {
    local warning
    for warning in "${GIT_WORKTREE_WARNINGS[@]}"; do
        log_info "${YELLOW}$warning${NC}"
    done
    [[ -n "$GIT_WORKTREE_COMMON_DIR" ]] || return 0
    # A working directory inside its own repository's .git is left alone, and a
    # common dir inside the working directory is already mounted.
    path_is_within "$WORKING_DIR" "$GIT_WORKTREE_COMMON_DIR" && return 0
    path_is_within "$GIT_WORKTREE_COMMON_DIR" "$WORKING_DIR" && return 0
    BWRAP_ARGS+=(--bind "$GIT_WORKTREE_COMMON_DIR" "$GIT_WORKTREE_COMMON_DIR")
    GIT_LINKED_DIRS+=("$GIT_WORKTREE_COMMON_DIR")
    log_info "${GREEN}✓${NC} Mounted linked git directory read-write: $GIT_WORKTREE_COMMON_DIR"
}

# Bind Claude Code configuration and state from the active profile
mount_claude_config() {
    prepare_profile_home
    warn_shadowed_binds "$HOME/.claude"
    warn_shadowed_binds "$HOME/.claude.json"

    # ~/.claude holds settings, credentials, memory, plugins, history;
    # ~/.claude.json holds onboarding state, account and per-project trust.
    # A fresh profile starts with an empty directory and an empty JSON object.
    bind_profile_dir ".claude"
    overlay_shared_profile_dir ".claude/skills" "claude-skills"
    bind_profile_file ".claude.json" "{}"
    if [[ -f "$PROFILE_HOME/.claude.json.backup" ]]; then
        BWRAP_ARGS+=(--bind "$PROFILE_HOME/.claude.json.backup" "$HOME/.claude.json.backup")
    fi

    # A CLAUDE_CONFIG_DIR inherited from the host would bypass the profile mount
    BWRAP_ARGS+=(--unsetenv CLAUDE_CONFIG_DIR)
}

# Mount a skills directory that OpenCode reads besides its own (~/.claude/skills,
# ~/.agents/skills). The default profile gets the host directory when it exists;
# a named profile gets its own directory, with the host's skills shared
# underneath (see overlay_shared_profile_dir).
# Usage: mount_opencode_external_skills <rel> <work-name>
mount_opencode_external_skills() {
    local rel="$1"
    local work_name="$2"

    if [[ "$PROFILE" == "default" ]]; then
        [[ -d "$HOME/$rel" ]] || return 0
        if is_path_bound "$HOME/$rel"; then
            log_info "${GREEN}✓${NC} ~/$rel already visible via existing mount"
        else
            BWRAP_ARGS+=(--bind "$HOME/$rel" "$HOME/$rel")
            log_info "${GREEN}✓${NC} Mounted ~/$rel (read-write)"
        fi
        return 0
    fi

    warn_shadowed_binds "$HOME/$rel"
    bind_profile_dir "$rel"
    overlay_shared_profile_dir "$rel" "$work_name"
}

# Bind OpenCode configuration and state from the active profile. The
# installation directory ~/.opencode (contains the binary) stays shared.
mount_opencode_config() {
    prepare_profile_home

    if [[ -d "$HOME/.opencode" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.opencode" "$HOME/.opencode")
        log_info "${GREEN}✓${NC} Mounted ~/.opencode (read-write, shared installation)"
    fi

    bind_profile_file ".opencode.json"
    # OpenCode follows the XDG Base Directory Specification
    bind_profile_dir ".config/opencode"
    overlay_shared_profile_dir ".config/opencode/skills" "opencode-skills"
    # OpenCode also loads Claude-compatible and agent-neutral skills
    mount_opencode_external_skills ".claude/skills" "claude-skills"
    mount_opencode_external_skills ".agents/skills" "agents-skills"
    bind_profile_dir ".cache/opencode"
    bind_profile_dir ".local/state/opencode"
    bind_profile_dir ".local/share/opencode"

    # XDG_* and OpenCode path overrides inherited from the host would bypass
    # the profile mounts
    BWRAP_ARGS+=(--unsetenv XDG_CONFIG_HOME --unsetenv XDG_CACHE_HOME)
    BWRAP_ARGS+=(--unsetenv XDG_STATE_HOME --unsetenv XDG_DATA_HOME)
    BWRAP_ARGS+=(--unsetenv OPENCODE_CONFIG_DIR --unsetenv OPENCODE_DB)
}

prepare_claude_native_install() {
    local managed_launcher="$CLAUDE_SANDBOX_BIN_DIR/claude"
    local host_target="" managed_target=""

    # ~/.local/bin is mounted as an overlay: the host directory is the
    # read-only lower layer and the managed dir is the writable upper layer,
    # so the updater can atomically replace ~/.local/bin/claude inside the
    # sandbox (the write lands in the upper layer and persists) without the
    # sandbox getting write access to the rest of ~/.local/bin.
    if [[ -L "$CLAUDE_HOST_BIN" ]]; then
        host_target=$(readlink -f "$CLAUDE_HOST_BIN" 2>/dev/null || true)
        if [[ "$host_target" != "$CLAUDE_NATIVE_DIR/versions/"* || ! -x "$host_target" ]]; then
            host_target=""
        fi
    fi
    if [[ -L "$managed_launcher" ]]; then
        managed_target=$(readlink -f "$managed_launcher" 2>/dev/null || true)
        if [[ "$managed_target" != "$CLAUDE_NATIVE_DIR/versions/"* || ! -x "$managed_target" ]]; then
            managed_target=""
        fi
    fi

    # Keep the upper-layer launcher only while it is strictly newer than the
    # host's (an in-sandbox update the host hasn't caught up to). Otherwise
    # remove it — including broken symlinks and stale whiteouts — so the host
    # launcher shows through the lower layer.
    if [[ -e "$managed_launcher" || -L "$managed_launcher" ]]; then
        local host_ver="${host_target##*/}" managed_ver="${managed_target##*/}"
        if [[ -z "$managed_target" ]] || { [[ -n "$host_target" ]] && \
            [[ "$(printf '%s\n' "$managed_ver" "$host_ver" | sort -V | tail -n1)" == "$host_ver" ]]; }; then
            rm -f "$managed_launcher"
            managed_target=""
        fi
    fi

    if [[ -n "$host_target" || -n "$managed_target" ]]; then
        mkdir -p "$CLAUDE_SANDBOX_BIN_DIR" "$CLAUDE_SANDBOX_WORK_DIR"
        CLAUDE_NATIVE_INSTALL=true
    fi
}

# OpenCode 1 and 2 have different command lines (see build_opencode_launch_args),
# so the major version is read from the installed binary before the sandbox
# starts. Unknown or unreadable versions are treated as the current major (2).
OPENCODE_MAJOR_VERSION=""
detect_opencode_version() {
    local output=""
    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout 15 "$AGENT_BIN" --version 2>/dev/null) || output=""
    else
        output=$("$AGENT_BIN" --version 2>/dev/null) || output=""
    fi
    if [[ "$output" =~ ([0-9]+)\.[0-9]+ ]]; then
        OPENCODE_MAJOR_VERSION="${BASH_REMATCH[1]}"
    else
        OPENCODE_MAJOR_VERSION=2
        log_info "${YELLOW}⚠${NC} Could not detect the OpenCode version from '$AGENT_BIN --version', assuming OpenCode 2"
    fi
}

# --- Claude Code command line --------------------------------------------------
#
# The sandbox is the safety net, so Claude Code normally runs with
# --dangerously-skip-permissions. An orchestrator such as T3 Code chooses the
# permission mode itself (--permission-mode <mode>, plus
# --dangerously-skip-permissions for its "Full access" mode); forcing the flag
# would silently turn its supervised modes into full access.
claude_should_add_skip_permissions() {
    local arg
    for arg in "${AGENT_ARGS[@]}"; do
        case "$arg" in
            --permission-mode|--permission-mode=*|--dangerously-skip-permissions|--allow-dangerously-skip-permissions)
                return 1
                ;;
        esac
    done
    return 0
}

# --- OpenCode 1 command line ---------------------------------------------------

opencode1_option_takes_value() {
    case "$1" in
        --agent|--attach|--command|--dir|--file|--hostname|--log-level|--mdns-domain|--method|--model|--password|--port|--prompt|--session|--title|--username|--variant|-f|-m|-p|-s|-u)
            return 0
            ;;
    esac

    return 1
}

opencode1_command_accepts_default_agent() {
    case "$1" in
        ""|run)
            return 0
            ;;
        acp|agent|attach|auth|completion|db|debug|export|github|import|mcp|models|plugin|plug|pr|providers|serve|session|stats|uninstall|upgrade|web)
            return 1
            ;;
    esac

    # Non-command positionals are treated as the default command's project path.
    return 0
}

opencode1_should_add_default_agent() {
    local arg
    local consume_next=false
    local explicit_agent=false

    for arg in "${AGENT_ARGS[@]}"; do
        if [[ "$consume_next" = true ]]; then
            consume_next=false
            continue
        fi

        case "$arg" in
            --)
                break
                ;;
            --agent|--agent=*)
                explicit_agent=true
                if [[ "$arg" != *=* ]]; then
                    consume_next=true
                fi
                continue
                ;;
            --*=*)
                continue
                ;;
            --*)
                if opencode1_option_takes_value "$arg"; then
                    consume_next=true
                fi
                continue
                ;;
            -f|-m|-p|-s|-u)
                consume_next=true
                continue
                ;;
            -*)
                continue
                ;;
            *)
                if [[ "$explicit_agent" = true ]]; then
                    return 1
                fi
                opencode1_command_accepts_default_agent "$arg"
                return
                ;;
        esac
    done

    [[ "$explicit_agent" = false ]]
}

# --- OpenCode 2 command line ---------------------------------------------------
#
# OpenCode 2 connects every command to one shared background server per user,
# discovered through ~/.local/state/opencode/service.json and reached over the
# loopback interface. The server owns tool execution, so from inside the sandbox
# (shared network namespace, state directory bound from the profile) the agent
# would run its commands outside the sandbox. --standalone makes the client
# spawn a private server as its own child instead, which keeps everything
# inside. Permissions are a flag now (--auto) rather than OPENCODE_PERMISSION.

opencode2_option_takes_value() {
    case "$1" in
        --server|--session|--prompt|--model|--agent|--format|--file|--title|--replay-limit|--log-level|--completions|-s|-m|-f)
            return 0
            ;;
    esac

    return 1
}

# Fills AGENT_LAUNCH_ARGS from AGENT_ARGS, inserting --standalone after the
# (sub)command for every command that accepts it and --auto for the two
# commands with permission flags (the TUI and run). Flags the user passed
# themselves are respected.
build_opencode2_launch_args() {
    local -a positionals=()
    local -a positional_index=()
    local consume_next=false
    local has_server_flag=false
    local has_permission_flag=false
    local explicit_server=false
    local i arg

    for ((i = 0; i < ${#AGENT_ARGS[@]}; i++)); do
        arg="${AGENT_ARGS[i]}"
        if [[ "$consume_next" = true ]]; then
            consume_next=false
            continue
        fi

        case "$arg" in
            --)
                break
                ;;
            --standalone)
                has_server_flag=true
                ;;
            --server|--server=*)
                has_server_flag=true
                explicit_server=true
                if [[ "$arg" == "--server" ]]; then
                    consume_next=true
                fi
                ;;
            --auto|--yolo|--dangerously-skip-permissions)
                has_permission_flag=true
                ;;
            --*=*)
                ;;
            -*)
                if opencode2_option_takes_value "$arg"; then
                    consume_next=true
                fi
                ;;
            *)
                positionals+=("$arg")
                positional_index+=("$i")
                ;;
        esac
    done

    local command="${positionals[0]:-}"
    local subcommand="${positionals[1]:-}"
    local insert_at=0
    local add_server=false
    local add_permission=false

    case "$command" in
        "")
            # Interactive TUI
            add_server=true
            add_permission=true
            ;;
        run)
            add_server=true
            add_permission=true
            insert_at=$((positional_index[0] + 1))
            ;;
        api|models|stats|mini|reload)
            add_server=true
            insert_at=$((positional_index[0] + 1))
            ;;
        session)
            case "$subcommand" in
                list|delete|export|import)
                    add_server=true
                    insert_at=$((positional_index[1] + 1))
                    ;;
            esac
            ;;
        auth)
            case "$subcommand" in
                list|login|logout|export|import|switch)
                    add_server=true
                    insert_at=$((positional_index[1] + 1))
                    ;;
            esac
            ;;
        upgrade|update|uninstall|acp|debug|mcp|plugin|pair|serve|service)
            # No --standalone/--auto flags on these commands
            ;;
        *)
            # Any other positional is the TUI's project directory argument
            add_server=true
            add_permission=true
            ;;
    esac

    if [[ "$has_server_flag" = true ]]; then
        add_server=false
    fi
    if [[ "$has_permission_flag" = true ]]; then
        add_permission=false
    fi
    if [[ "$explicit_server" = true ]]; then
        log_info "${YELLOW}⚠${NC} --server given: OpenCode will execute tools on that server, outside the sandbox"
    fi

    AGENT_LAUNCH_ARGS=("${AGENT_ARGS[@]:0:insert_at}")
    if [[ "$add_server" = true ]]; then
        AGENT_LAUNCH_ARGS+=(--standalone)
    fi
    if [[ "$add_permission" = true ]]; then
        AGENT_LAUNCH_ARGS+=(--auto)
    fi
    AGENT_LAUNCH_ARGS+=("${AGENT_ARGS[@]:insert_at}")
}

# --- Main ----------------------------------------------------------------------
#
# Everything above only defines functions and defaults. When the script is
# sourced (the bats tests in tests/ do this to call single functions), stop
# here so nothing is parsed, mounted or started.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

resolve_git_worktree
load_config_files

# The environment variable beats config files on purpose: a repository must not
# be able to silently switch the credentials a user chose in their shell.
if [[ -n "${AI_AGENT_SANDBOX_PROFILE:-}" ]]; then
    PROFILE="$AI_AGENT_SANDBOX_PROFILE"
    PROFILE_SOURCE="AI_AGENT_SANDBOX_PROFILE"
fi

# A project that names a profile may not switch the profile, but it may refuse
# to run under a different one coming from the environment. Orchestrators such
# as T3 Code set AI_AGENT_SANDBOX_PROFILE per provider instance, so picking the
# wrong instance in a new thread would otherwise bill the wrong subscription.
# An instance without the variable uses the host configuration (T3 reads its
# transcripts and usage from there), so with --strict-profile (passed by the
# orchestrator's wrapper) a missing variable counts as "default". Otherwise the
# project's profile simply applies. An explicit --profile is a deliberate
# choice and wins.
check_project_profile() {
    [[ -n "$PROJECT_PROFILE" ]] || return 0
    local requested origin
    if [[ "$PROFILE_SOURCE" == AI_AGENT_SANDBOX_PROFILE ]]; then
        requested="$PROFILE"
        origin="AI_AGENT_SANDBOX_PROFILE is '$requested'"
    elif [[ "$STRICT_PROFILE" = true && "$PROFILE_SOURCE" != --profile ]]; then
        requested="default"
        origin="AI_AGENT_SANDBOX_PROFILE is not set (counts as 'default' with --strict-profile)"
    else
        return 0
    fi
    [[ "$PROJECT_PROFILE" != "$requested" ]] || return 0
    echo -e "${RED}Error: profile mismatch: $PROJECT_PROFILE_SOURCE requires profile '$PROJECT_PROFILE', but $origin${NC}" >&2
    echo "In an orchestrator such as T3 Code, start the thread with the provider instance of profile '$PROJECT_PROFILE'." >&2
    echo "To run under '$requested' anyway, pass --profile $requested." >&2
    exit 1
}

if [[ -n "${AI_AGENT_SANDBOX_NETWORK:-}" ]]; then
    validate_network_mode "$AI_AGENT_SANDBOX_NETWORK" || { echo -e "${RED}Error: invalid AI_AGENT_SANDBOX_NETWORK '$AI_AGENT_SANDBOX_NETWORK' (expected isolated, host or none)${NC}" >&2; exit 1; }
    NETWORK_MODE="$AI_AGENT_SANDBOX_NETWORK"
    NETWORK_MODE_SOURCE="AI_AGENT_SANDBOX_NETWORK"
fi

# Parse command line arguments (kept for the restart after a config migration)
ORIGINAL_ARGS=("$@")
AGENT_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --whitelist|--blacklist|--env-path)
            echo -e "${RED}Error: $1 is no longer supported, put the entries into the whitelist, blacklist or env key of a config.yaml${NC}" >&2
            exit 1
            ;;
        --profile|-p)
            PROFILE="$2"
            PROFILE_SOURCE="--profile"
            shift 2
            ;;
        --list-profiles)
            LIST_PROFILES=true
            shift
            ;;
        --strict-profile)
            STRICT_PROFILE=true
            shift
            ;;
        --allow-home-workdir)
            ALLOW_HOME_WORKDIR=true
            shift
            ;;
        --migrate-project-conf)
            MIGRATE_PROJECT_CONFIG=true
            shift
            ;;
        --no-docker)
            ENABLE_DOCKER=false
            shift
            ;;
        --no-venv)
            ENABLE_VENV=false
            shift
            ;;
        --gitconfig)
            MOUNT_GITCONFIG=true
            shift
            ;;
        --no-gpg-agent)
            ENABLE_GPG_AGENT=false
            shift
            ;;
        --no-protect-project-config)
            PROTECT_PROJECT_CONFIG=false
            shift
            ;;
        --env|-e)
            ENV_VARS+=("$2")
            shift 2
            ;;
        --blacklist-path)
            BLACKLIST_PATHS+=("$2")
            EXPLICIT_BLACKLIST=true
            shift 2
            ;;
        --whitelist-path)
            WHITELIST_PATHS_RO+=("$2")
            EXPLICIT_WHITELIST=true
            shift 2
            ;;
        --whitelist-path-rw)
            WHITELIST_PATHS_RW+=("$2")
            EXPLICIT_WHITELIST=true
            shift 2
            ;;
        --enable-docker|-d)
            ENABLE_DOCKER=true
            shift
            ;;
        --venv)
            ENABLE_VENV=true
            shift
            ;;
        --no-gitconfig)
            MOUNT_GITCONFIG=false
            shift
            ;;
        --shared-skills)
            SHARE_SKILLS=true
            shift
            ;;
        --no-shared-skills)
            SHARE_SKILLS=false
            shift
            ;;
        --gpg-agent)
            ENABLE_GPG_AGENT=true
            shift
            ;;
        --docker-image)
            SOCKET_PROXY_IMAGE="$2"
            shift 2
            ;;
        --network)
            validate_network_mode "$2" || { echo -e "${RED}Error: invalid --network mode '$2' (expected isolated, host or none)${NC}" >&2; exit 1; }
            NETWORK_MODE="$2"
            NETWORK_MODE_SOURCE="--network"
            shift 2
            ;;
        --host-port)
            validate_host_port "$2" || { echo -e "${RED}Error: invalid --host-port '$2' (expected a TCP port or range a-b)${NC}" >&2; exit 1; }
            NETWORK_HOST_PORTS+=("$2")
            shift 2
            ;;
        --allow-host)
            NETWORK_ALLOW_HOSTS+=("$2")
            shift 2
            ;;
        --agent|-a)
            AGENT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --verbose|-v)
            QUIET=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            AGENT_ARGS=("$@")
            break
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}" >&2
            usage
            ;;
    esac
done

# Configuration files were parsed before the command line so that flags win;
# now that --quiet/--verbose are known, report what the parser had to say.
# A bare version query is answered by the host binary without a sandbox (see
# below); decided before agent_args from the config are prepended.
if [[ ${#AGENT_ARGS[@]} -eq 1 && ( "${AGENT_ARGS[0]}" == "--version" || "${AGENT_ARGS[0]}" == "-v" ) ]]; then
    VERSION_QUERY=true
fi
AGENT_ARGS=("${CONFIG_AGENT_ARGS[@]}" "${AGENT_ARGS[@]}")
flush_config_log

if [[ "$LIST_PROFILES" = true ]]; then
    list_profiles
    exit 0
fi

USER_LEGACY_FILES=()
for legacy_file in "$DEFAULT_WHITELIST_FILE" "$DEFAULT_BLACKLIST_FILE" \
    "$DEFAULT_ENV_FILE" "$DEFAULT_ENV_LOCAL_FILE"; do
    if [[ -f "$legacy_file" ]]; then
        USER_LEGACY_FILES+=("$legacy_file")
    fi
done
PROJECT_LEGACY_FILES=()
for legacy_file in "$PROJECT_WHITELIST_FILE" "$PROJECT_BLACKLIST_FILE" \
    "$PROJECT_ENV_FILE" "$PROJECT_ENV_LOCAL_FILE"; do
    if [[ -f "$legacy_file" ]]; then
        PROJECT_LEGACY_FILES+=("$legacy_file")
    fi
done

USER_HAS_YAML=false
if [[ -f "$DEFAULT_CONFIG_FILE" || -f "$DEFAULT_CONFIG_LOCAL_FILE" ]]; then
    USER_HAS_YAML=true
fi
PROJECT_HAS_YAML=false
if [[ -f "$PROJECT_CONFIG_FILE" || -f "$PROJECT_CONFIG_LOCAL_FILE" || -n "$MAIN_CHECKOUT_CONFIG_LOCAL_FILE" ]]; then
    PROJECT_HAS_YAML=true
fi

if [[ "$MIGRATE_PROJECT_CONFIG" = true ]]; then
    if [[ ${#PROJECT_LEGACY_FILES[@]} -eq 0 ]]; then
        echo "No legacy configuration files found in $PROJECT_CONFIG_DIR, nothing to migrate" >&2
        exit 0
    fi
    explain_legacy_migration "$PROJECT_CONFIG_FILE" "$PROJECT_CONFIG_LOCAL_FILE" \
        "$PROJECT_HAS_YAML" "${PROJECT_LEGACY_FILES[@]}"
    echo >&2
    migrate_legacy_config "$PROJECT_CONFIG_FILE" "$PROJECT_CONFIG_LOCAL_FILE" \
        "$PROJECT_WHITELIST_FILE" "$PROJECT_BLACKLIST_FILE" \
        "$PROJECT_ENV_FILE" "$PROJECT_ENV_LOCAL_FILE" || exit 1
    echo -e "\n${GREEN}Project configuration migrated.${NC} Review the result, delete the *.migrated files and commit." >&2
    echo "Team members need a sandbox version that supports config.yaml before they pull this change." >&2
    if [[ -n "${MIGRATED_TARGETS[*]}" && " ${MIGRATED_TARGETS[*]} " == *" $PROJECT_CONFIG_LOCAL_FILE "* ]] \
        && git -C "$WORKING_DIR" rev-parse --is-inside-work-tree &>/dev/null \
        && ! git -C "$WORKING_DIR" check-ignore -q "$PROJECT_CONFIG_LOCAL_FILE"; then
        echo -e "${YELLOW}Warning: $PROJECT_CONFIG_LOCAL_FILE is not ignored by git; add it to .gitignore, it holds the former .env.local entries${NC}" >&2
    fi
    exit 0
fi

# Offer to migrate the user-level files when someone can answer. After a
# successful migration the script restarts so the new config.yaml is loaded
# with the usual precedence (config files are parsed before the command line).
if [[ ${#USER_LEGACY_FILES[@]} -gt 0 && -t 0 && -t 2 ]]; then
    explain_legacy_migration "$DEFAULT_CONFIG_FILE" "$DEFAULT_CONFIG_LOCAL_FILE" \
        "$USER_HAS_YAML" "${USER_LEGACY_FILES[@]}"
    migrate_answer=""
    read -r -p "Migrate your user-level configuration now? [y/N] " migrate_answer || migrate_answer=""
    case "$migrate_answer" in
        y|Y|yes|Yes|YES)
            if migrate_legacy_config "$DEFAULT_CONFIG_FILE" "$DEFAULT_CONFIG_LOCAL_FILE" \
                "$DEFAULT_WHITELIST_FILE" "$DEFAULT_BLACKLIST_FILE" \
                "$DEFAULT_ENV_FILE" "$DEFAULT_ENV_LOCAL_FILE"; then
                echo -e "${GREEN}User configuration migrated, restarting with $DEFAULT_CONFIG_FILE${NC}\n" >&2
                exec "$BASH" "$0" "${ORIGINAL_ARGS[@]}"
            fi
            ;;
        *)
            echo "Not migrating; you will be asked again on the next start." >&2
            ;;
    esac
fi

warn_legacy_files "user-level" "$DEFAULT_CONFIG_FILE" "$USER_HAS_YAML" \
    "start the sandbox in a terminal to migrate them automatically" "${USER_LEGACY_FILES[@]}"
warn_legacy_files "project-level" "$PROJECT_CONFIG_FILE" "$PROJECT_HAS_YAML" \
    "run with --migrate-project-conf to migrate them" "${PROJECT_LEGACY_FILES[@]}"

if [[ -z "$PROFILE" ]]; then
    PROFILE="default"
    PROFILE_SOURCE="default"
fi
check_project_profile
validate_profile_name
resolve_profile_home

trap cleanup_sandbox EXIT
trap 'forward_signal_and_exit HUP "$SIGHUP_EXIT_STATUS"' HUP
trap 'forward_signal_and_exit TERM "$SIGTERM_EXIT_STATUS"' TERM
# Ctrl+C belongs to the agent: a trapped (not ignored) signal keeps the default
# disposition in the children, and bash just returns to waiting. bwrap itself
# ignores SIGINT, so the sandbox survives it like a foreground child would.
trap ':' INT

# Validate agent selection
if [[ "$AGENT" != "claudecode" ]] && [[ "$AGENT" != "opencode" ]]; then
    echo -e "${RED}Error: Invalid agent '$AGENT'. Must be 'claudecode' or 'opencode'${NC}" >&2
    exit 1
fi

# Detect agent binary based on selection
AGENT_BIN=""
if [[ "$AGENT" = "claudecode" ]]; then
    prepare_claude_native_install
    if [[ "$CLAUDE_NATIVE_INSTALL" = true ]]; then
        AGENT_BIN="$CLAUDE_HOST_BIN"
    else
        AGENT_BIN=$(command -v claude 2>/dev/null || true)
    fi
    if [[ -z "$AGENT_BIN" && "$DRY_RUN" = false ]]; then
        echo -e "${RED}Error: claude is not installed${NC}" >&2
        echo "Install it from: https://docs.claude.com/en/docs/claude-code" >&2
        exit 1
    fi
elif [[ "$AGENT" = "opencode" ]]; then
    AGENT_BIN="$HOME/.opencode/bin/opencode"
    if [[ ! -x "$AGENT_BIN" && "$DRY_RUN" = false ]]; then
        echo -e "${RED}Error: opencode is not installed at $AGENT_BIN${NC}" >&2
        echo "Install it from: https://opencode.dev" >&2
        exit 1
    fi
fi

# Orchestrators such as T3 Code check the agent with a bare --version, in their
# own working directory (often the home directory) and with a short timeout.
# Starting a sandbox there would scan the whole directory for blacklist matches
# and could exceed the timeout, so the host binary answers directly: the sandbox
# runs the same binary, and the script runs `opencode --version` on the host
# anyway to detect the version. Claude reports the upper-layer launcher when an
# in-sandbox update made it newer than the host's.
if [[ "$VERSION_QUERY" = true && "$DRY_RUN" = false ]]; then
    VERSION_BIN="$AGENT_BIN"
    if [[ "$AGENT" = "claudecode" && "$CLAUDE_NATIVE_INSTALL" = true && -x "$CLAUDE_SANDBOX_BIN_DIR/claude" ]]; then
        VERSION_BIN="$CLAUDE_SANDBOX_BIN_DIR/claude"
    fi
    exec "$VERSION_BIN" "${AGENT_ARGS[@]: -1}"
fi

# Refuse to run in the home directory or one of its parents: the working
# directory is bound read-write, so the agent would get the whole home directory
# (SSH keys, credentials, every other project) with only the blacklist applied.
# T3 Code starts OpenCode's shared server in its own working directory, which is
# usually the home directory, so this also stops that setup from silently
# running unconfined.
REAL_WORKING_DIR=$(realpath -m "$WORKING_DIR")
REAL_HOME=$(realpath -m "$HOME")
if [[ "$ALLOW_HOME_WORKDIR" = false ]] \
    && [[ "$REAL_HOME" == "$REAL_WORKING_DIR" || "$REAL_HOME" == "${REAL_WORKING_DIR%/}/"* ]]; then
    if [[ "$REAL_HOME" == "$REAL_WORKING_DIR" ]]; then
        echo -e "${RED}Error: the working directory $WORKING_DIR is your home directory${NC}" >&2
    else
        echo -e "${RED}Error: the working directory $WORKING_DIR contains your home directory${NC}" >&2
    fi
    echo "The agent would get read-write access to all of it. Run the sandbox from a project" >&2
    echo "directory, or pass --allow-home-workdir if this is really what you want." >&2
    if [[ "$AGENT" = "opencode" ]]; then
        echo "T3 Code runs one OpenCode server in its own working directory for all projects;" >&2
        echo "that setup cannot be sandboxed per project (see README, T3 Code section)." >&2
    fi
    exit 1
fi

if [[ "$AGENT" = "opencode" ]] && [[ -x "$AGENT_BIN" ]]; then
    detect_opencode_version
fi

validate_docker
validate_gpg_agent
detect_venv

# Cache command availability checks
BWRAP_BIN=$(command -v bwrap 2>/dev/null)

# Check if bubblewrap is installed
if [[ -z "$BWRAP_BIN" ]]; then
    echo -e "${RED}Error: bubblewrap (bwrap) is not installed${NC}" >&2
    echo "Install it with: sudo apt install bubblewrap (Debian/Ubuntu) or sudo dnf install bubblewrap (Fedora)" >&2
    exit 1
fi

resolve_network_mode

# Create a default user-level config.yaml on first run: no user-level
# configuration of either kind exists and the whitelist or blacklist was not
# given explicitly. Only the sections that were not given explicitly are written.
if [[ "$USER_HAS_YAML" = false && ${#USER_LEGACY_FILES[@]} -eq 0 ]] \
    && [[ "$EXPLICIT_WHITELIST" = false || "$EXPLICIT_BLACKLIST" = false ]]; then
    echo -e "${YELLOW}Warning: No user-level configuration found, creating default $DEFAULT_CONFIG_FILE${NC}" >&2
    mkdir -p "$(dirname "$DEFAULT_CONFIG_FILE")"
    {
        cat << 'EOHEADER'
# AI Agent Sandbox configuration
# See config-example.yaml in the ai-agent-sandbox repository for all keys.
EOHEADER
        if [[ "$EXPLICIT_WHITELIST" = false ]]; then
            cat << 'EOWHITELIST'

# Paths the agent can read (absolute or relative to the working directory).
# Globs and ** patterns are supported, suffix ":rw" for read-write access,
# prefix "!" to re-allow a path hidden by the blacklist.
whitelist:
  # Essential system directories
  - /usr/bin
  - /usr/lib
  - /usr/lib64
  - /usr/share
  - /lib
  - /lib64
  - /bin
  - /sbin
  # Common development tools locations
  - /usr/local/bin
  - /usr/local/lib
  # System configuration that's generally safe
  - /etc/alternatives
  - /etc/ssl/certs
EOWHITELIST
        fi
        if [[ "$EXPLICIT_BLACKLIST" = false ]]; then
            cat << 'EOBLACKLIST'

# Paths relative to the working directory that the agent cannot access
blacklist:
  # Common sensitive files
  - "**/.env"
  # SSH and crypto keys
  - "**/.ssh"
  - "**/*.pem"
  - "**/*.key"
  - "**/id_rsa"
  - "**/id_ed25519"
  - "**/*.p12"
  - "**/*.pfx"
  # AWS credentials
  - "**/.aws/credentials"
  # Docker and Kubernetes secrets
  - "**/docker-compose.override.yml"
  - "**/.kube/config"
  # Password managers
  - "**/*.kdbx"
  - "**/*.agilekeychain"
  - "**/.vault_password"
EOBLACKLIST
        fi
    } > "$DEFAULT_CONFIG_FILE"
    echo -e "${GREEN}Created default configuration at $DEFAULT_CONFIG_FILE${NC}" >&2
    echo -e "${YELLOW}Please review and customize it for your needs${NC}" >&2

    # Config files were parsed before the command line; the new file only holds
    # list entries, which are merged, so parsing it now keeps flags in charge.
    # Its entries go first, as if it had been loaded with the other user files.
    saved_whitelist_entries=("${WHITELIST_ENTRIES[@]}")
    saved_blacklist_paths=("${BLACKLIST_PATHS[@]}")
    WHITELIST_ENTRIES=()
    BLACKLIST_PATHS=()
    parse_config_file "$DEFAULT_CONFIG_FILE"
    WHITELIST_ENTRIES+=("${saved_whitelist_entries[@]}")
    BLACKLIST_PATHS+=("${saved_blacklist_paths[@]}")
    CONFIG_FILES_LOADED=("$DEFAULT_CONFIG_FILE" "${CONFIG_FILES_LOADED[@]}")
    flush_config_log
    USER_HAS_YAML=true
fi

# Legacy user-level files go first, legacy project-level files after them
if [[ "$USER_HAS_YAML" = false ]]; then
    if [[ -f "$DEFAULT_WHITELIST_FILE" ]]; then
        WHITELIST_FILES+=("$DEFAULT_WHITELIST_FILE")
    fi
    if [[ -f "$DEFAULT_BLACKLIST_FILE" ]]; then
        BLACKLIST_FILES+=("$DEFAULT_BLACKLIST_FILE")
    fi
    if [[ -f "$DEFAULT_ENV_FILE" ]]; then
        ENV_FILES+=("$DEFAULT_ENV_FILE")
    fi
    if [[ -f "$DEFAULT_ENV_LOCAL_FILE" ]]; then
        ENV_FILES+=("$DEFAULT_ENV_LOCAL_FILE")
    fi
fi
if [[ "$PROJECT_HAS_YAML" = false ]]; then
    if [[ -f "$PROJECT_WHITELIST_FILE" ]]; then
        WHITELIST_FILES+=("$PROJECT_WHITELIST_FILE")
    fi
    if [[ -f "$PROJECT_BLACKLIST_FILE" ]]; then
        BLACKLIST_FILES+=("$PROJECT_BLACKLIST_FILE")
    fi
    if [[ -f "$PROJECT_ENV_FILE" ]]; then
        ENV_FILES+=("$PROJECT_ENV_FILE")
    fi
    if [[ -f "$PROJECT_ENV_LOCAL_FILE" ]]; then
        ENV_FILES+=("$PROJECT_ENV_LOCAL_FILE")
    fi
fi

# Build bubblewrap arguments
BWRAP_ARGS=(
    # Create new namespaces (including network namespace for isolation)
    --unshare-all
    --die-with-parent

    # Proc and dev
    --proc /proc
    --dev /dev

    # Tmp directories
    --tmpfs /tmp

    # Make root readonly
    --ro-bind /sys /sys
)

# Setup minimal home directory using tmpfs
BWRAP_ARGS+=(--tmpfs "$HOME")
BLACKLIST_SEARCH_ROOTS+=("$WORKING_DIR")

# Bind working directory (after tmpfs home, so it's visible)
BWRAP_ARGS+=(--bind "$WORKING_DIR" "$WORKING_DIR")
protect_project_config_dir
mount_git_linked_dirs

# Forward gpg-agent before whitelist processing: bwrap does not change the mode
# of directories that already exist, and gpg requires /run/user/<uid> to be 0700
mount_gpg_agent

# Process all whitelist files and add to bubblewrap (after tmpfs so HOME paths work)
if [[ ${#WHITELIST_FILES[@]} -eq 0 && ${#WHITELIST_ENTRIES[@]} -eq 0 \
    && ${#WHITELIST_PATHS_RO[@]} -eq 0 && ${#WHITELIST_PATHS_RW[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No whitelist entries found${NC}" >&2
    exit 1
fi

for WHITELIST_FILE in "${WHITELIST_FILES[@]}"; do
    if [[ ! -f "$WHITELIST_FILE" ]]; then
        echo -e "${YELLOW}Warning: Whitelist file not found: $WHITELIST_FILE (skipping)${NC}" >&2
        continue
    fi

    log_info "${GREEN}Processing whitelist:${NC} $WHITELIST_FILE"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        line=$(strip_inline_comment "$line")
        [[ -z "$line" ]] && continue

        process_whitelist_entry "$line"
    done < "$WHITELIST_FILE"
done

# Process whitelist entries from config files (same syntax as whitelist files)
if [[ ${#WHITELIST_ENTRIES[@]} -gt 0 ]]; then
    log_info "${GREEN}Processing whitelist entries from config files:${NC}"
    for entry in "${WHITELIST_ENTRIES[@]}"; do
        process_whitelist_entry "$entry"
    done
fi

# Process direct whitelist paths (read-only)
if [[ ${#WHITELIST_PATHS_RO[@]} -gt 0 ]]; then
    log_info "${GREEN}Processing direct whitelist paths (read-only):${NC}"
    for path in "${WHITELIST_PATHS_RO[@]}"; do
        read -r override path < <(parse_whitelist_override "$path")
        [[ -z "$path" ]] && continue
        if [[ "$override" = "true" ]]; then
            whitelist_path "$path" "ro" "WHITELIST_OVERRIDE_ARGS" "Whitelisted (override)"
        else
            whitelist_path "$path" "ro" "BWRAP_ARGS" "Whitelisted"
        fi
    done
fi

# Process direct whitelist paths (read-write)
if [[ ${#WHITELIST_PATHS_RW[@]} -gt 0 ]]; then
    log_info "${GREEN}Processing direct whitelist paths (read-write):${NC}"
    for path in "${WHITELIST_PATHS_RW[@]}"; do
        read -r override path < <(parse_whitelist_override "$path")
        [[ -z "$path" ]] && continue
        if [[ "$override" = "true" ]]; then
            whitelist_path "$path" "rw" "WHITELIST_OVERRIDE_ARGS" "Whitelisted (override)"
        else
            whitelist_path "$path" "rw" "BWRAP_ARGS" "Whitelisted"
        fi
    done
fi

# Process all blacklist files and hide patterns with tmpfs overlays
if [[ ${#BLACKLIST_FILES[@]} -gt 0 ]]; then
    log_info "\n${YELLOW}Processing blacklist patterns:${NC}"
    for BLACKLIST_FILE in "${BLACKLIST_FILES[@]}"; do
        if [[ ! -f "$BLACKLIST_FILE" ]]; then
            log_info "${YELLOW}Warning: Blacklist file not found: $BLACKLIST_FILE (skipping)${NC}"
            continue
        fi

        log_info "${YELLOW}Processing blacklist:${NC} $BLACKLIST_FILE"

        while IFS= read -r pattern || [[ -n "$pattern" ]]; do
            [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${pattern// }" ]] && continue

            pattern=$(strip_inline_comment "$pattern")
            [[ -z "$pattern" ]] && continue

            # Process the pattern using the helper function
            blacklist_pattern "$pattern"
        done < "$BLACKLIST_FILE"
    done
fi

# Process direct blacklist paths
if [[ ${#BLACKLIST_PATHS[@]} -gt 0 ]]; then
    log_info "\n${YELLOW}Processing direct blacklist paths:${NC}"
    for pattern in "${BLACKLIST_PATHS[@]}"; do
        blacklist_pattern "$pattern"
    done
fi

# Apply whitelist overrides after blacklist so they take precedence
if [[ ${#WHITELIST_OVERRIDE_ARGS[@]} -gt 0 ]]; then
    log_info "\n${GREEN}Applying whitelist overrides (after blacklist):${NC}"
    BWRAP_ARGS+=("${WHITELIST_OVERRIDE_ARGS[@]}")
fi

# Never expose other profiles' credentials, even when a whitelist entry covers
# the profile store (e.g. ~/.local/share); the active profile is bound separately
if [[ -d "$PROFILES_DIR" ]] && is_path_bound "$PROFILES_DIR"; then
    BWRAP_ARGS+=(--tmpfs "$PROFILES_DIR")
    log_info "${YELLOW}✓${NC} Hidden profile store $PROFILES_DIR (covered by another mount)"
fi

if [[ "$ENABLE_VENV" = true ]]; then
    log_info "\n${GREEN}Virtual environment:${NC} $VENV_PATH"
    BWRAP_ARGS+=(--ro-bind "$VENV_PATH" "$VENV_PATH")
    sandbox_setenv VIRTUAL_ENV "$VENV_PATH"
    BWRAP_ARGS+=(--unsetenv PYTHONHOME)
    log_info "${GREEN}✓${NC} Mounted virtual environment: $VENV_PATH (read-only)"
fi

mount_docker_compose_plugins

log_info "\n${YELLOW}Agent-specific configuration bindings:"
if [[ "$AGENT" = "claudecode" ]]; then
    if [[ "$CLAUDE_NATIVE_INSTALL" = true ]]; then
        # Persist both parts of a native Claude installation. The updater writes
        # binaries under ~/.local/share and atomically replaces its launcher at
        # ~/.local/bin/claude. That path is mounted as an overlay (host dir as
        # read-only lower layer, managed dir as writable upper layer) so the
        # launcher swap persists across runs while the rest of ~/.local/bin
        # stays visible and effectively read-only on the host. Note: concurrent
        # sandboxes share the upper/work dirs, which overlayfs may refuse.
        BWRAP_ARGS+=(--bind "$CLAUDE_NATIVE_DIR" "$CLAUDE_NATIVE_DIR")
        if [[ -d "$HOME/.local/bin" ]] && bwrap_supports_overlay; then
            BWRAP_ARGS+=(--overlay-src "$HOME/.local/bin")
            BWRAP_ARGS+=(--overlay "$CLAUDE_SANDBOX_BIN_DIR" "$CLAUDE_SANDBOX_WORK_DIR" "$HOME/.local/bin")
            log_info "${GREEN}✓${NC} Mounted native Claude versions (read-write) and ~/.local/bin overlay (updates persist)"
        else
            # No overlay support: shadow ~/.local/bin with the managed dir so
            # updates still persist, at the cost of hiding its other entries.
            if [[ ! -e "$CLAUDE_SANDBOX_BIN_DIR/claude" ]] && [[ -x "$(readlink -f "$CLAUDE_HOST_BIN" 2>/dev/null)" ]]; then
                ln -s "$(readlink -f "$CLAUDE_HOST_BIN")" "$CLAUDE_SANDBOX_BIN_DIR/claude"
            fi
            BWRAP_ARGS+=(--bind "$CLAUDE_SANDBOX_BIN_DIR" "$HOME/.local/bin")
            log_info "${GREEN}✓${NC} Mounted native Claude versions and launcher (read-write, no overlay support)"
        fi
    # Bind non-native claude binary
    elif [[ -e "$HOME/.local/bin/claude" ]]; then
        # If it's a symlink, we need to bind the target first, then create the symlink
        if [[ -L "$HOME/.local/bin/claude" ]]; then
            CLAUDE_TARGET=$(readlink -f "$HOME/.local/bin/claude")
            if [[ -f "$CLAUDE_TARGET" ]]; then
                # Bind the actual binary/target
                BWRAP_ARGS+=(--ro-bind "$CLAUDE_TARGET" "$CLAUDE_TARGET")
                if is_path_bound "$HOME/.local/bin/claude"; then
                    # Symlink is already visible through an existing mount
                    # (e.g. whitelisted ~/.local/bin); creating it would fail.
                    log_info "${GREEN}✓${NC} Mounted $CLAUDE_TARGET (~/.local/bin/claude already visible via existing mount)"
                else
                    # Create a symlink in the sandbox
                    BWRAP_ARGS+=(--symlink "${CLAUDE_TARGET}" "$HOME/.local/bin/claude")
                    log_info "${GREEN}✓${NC} Mounted $CLAUDE_TARGET and created symlink at ~/.local/bin/claude (read-only)"
                fi
            fi
        elif [[ -x "$HOME/.local/bin/claude" ]]; then
            if is_path_bound "$HOME/.local/bin/claude"; then
                log_info "${GREEN}✓${NC} ~/.local/bin/claude already visible via existing mount"
            else
                # It's a regular file, bind it directly
                BWRAP_ARGS+=(--ro-bind "$HOME/.local/bin/claude" "$HOME/.local/bin/claude")
                log_info "${GREEN}✓${NC} Mounted ~/.local/bin/claude (read-only)"
            fi
        fi
    fi

    mount_claude_config
elif [[ "$AGENT" = "opencode" ]]; then
    mount_opencode_config
fi

# Bind ~/.gitconfig read-only so git identity and settings are available
if [[ "$MOUNT_GITCONFIG" = true ]] && [[ -f "$HOME/.gitconfig" ]]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.gitconfig" "$HOME/.gitconfig")
    log_info "${GREEN}✓${NC} Mounted ~/.gitconfig (read-only)"
fi

sandbox_setenv HOME "$HOME"
sandbox_setenv PWD "$WORKING_DIR"
BWRAP_ARGS+=(--chdir "$WORKING_DIR")

# Network configuration
case "$NETWORK_MODE" in
    host)
        log_info "\n${GREEN}Network: host network shared (full local and internet access)${NC}"
        BWRAP_ARGS+=(--share-net)
        # Use system DNS configuration
        if [[ -f /etc/resolv.conf ]]; then
            BWRAP_ARGS+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
        fi
        ;;
    isolated)
        log_info "\n${GREEN}Network: isolated (internet via pasta, host loopback and private networks blocked)${NC}"
        prepare_isolated_network
        ;;
    none)
        log_info "\n${GREEN}Network: none (no network access)${NC}"
        ;;
esac

# Bind /etc/hosts for name resolution
if [[ -f /etc/hosts ]]; then
    BWRAP_ARGS+=(--ro-bind /etc/hosts /etc/hosts)
fi

# Set minimal environment
sandbox_setenv TERM "${TERM:-xterm-256color}"
SANDBOX_PATH=""
if [[ "$AGENT" = "claudecode" ]]; then
    SANDBOX_PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
elif [[ "$AGENT" = "opencode" ]]; then
    SANDBOX_PATH="$HOME/.opencode/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
fi
if [[ "$ENABLE_VENV" = true ]]; then
    SANDBOX_PATH="$VENV_BIN_DIR:$SANDBOX_PATH"
fi
sandbox_setenv PATH "$SANDBOX_PATH"
BWRAP_ARGS+=(--unsetenv SSH_AUTH_SOCK)
BWRAP_ARGS+=(--unsetenv SSH_AGENT_PID)

if [[ "$ENABLE_DOCKER" = true ]]; then
    sandbox_setenv DOCKER_HOST "unix://$WORKING_DIR/.docker-proxy/docker.sock"
    sandbox_setenv TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE "$WORKING_DIR/.docker-proxy/docker.sock"
    sandbox_setenv TESTCONTAINERS_HOST_OVERRIDE "localhost"
fi

# Preserve agent-specific environment variables
if [[ "$AGENT" = "claudecode" ]]; then
    if [[ -n "${CLAUDECODE:-}" ]]; then
        sandbox_setenv CLAUDECODE "$CLAUDECODE"
    fi
    if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
        sandbox_setenv CLAUDE_CODE_ENTRYPOINT "$CLAUDE_CODE_ENTRYPOINT"
    fi
elif [[ "$AGENT" = "opencode" ]] && [[ -n "$OPENCODE_MAJOR_VERSION" && "$OPENCODE_MAJOR_VERSION" -lt 2 ]]; then
    # Force YOLO-style permissions inside sandboxed OpenCode 1 runs. OpenCode 2
    # ignores this variable; it gets --auto instead (build_opencode_launch_args).
    sandbox_setenv OPENCODE_PERMISSION '{"*":"allow"}'
fi

# Process environment files and direct environment variables last so explicit
# sandbox environment entries can override earlier defaults.
if [[ ${#ENV_FILES[@]} -gt 0 ]]; then
    log_info "\n${GREEN}Processing environment files:${NC}"
    for ENV_FILE in "${ENV_FILES[@]}"; do
        if [[ ! -f "$ENV_FILE" ]]; then
            log_info "${YELLOW}Warning: Environment file not found: $ENV_FILE (skipping)${NC}"
            continue
        fi

        log_info "${GREEN}Processing env:${NC} $ENV_FILE"

        while IFS= read -r line || [[ -n "$line" ]]; do
            trimmed_line=$(trim_whitespace "$line")
            [[ -z "$trimmed_line" || "$trimmed_line" =~ ^# ]] && continue
            set_sandbox_env "$line" "$ENV_FILE"
        done < "$ENV_FILE"
    done
fi

if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
    log_info "\n${GREEN}Processing direct environment variables:${NC}"
    for env_var in "${ENV_VARS[@]}"; do
        set_sandbox_env "$env_var" "--env"
    done
fi

# Build the agent command line (sandbox defaults merged with user args)
AGENT_LAUNCH_ARGS=()
if [[ "$AGENT" = "claudecode" ]]; then
    if claude_should_add_skip_permissions; then
        AGENT_LAUNCH_ARGS=(--dangerously-skip-permissions "${AGENT_ARGS[@]}")
    else
        AGENT_LAUNCH_ARGS=("${AGENT_ARGS[@]}")
    fi
elif [[ "$AGENT" = "opencode" ]]; then
    if [[ -n "$OPENCODE_MAJOR_VERSION" && "$OPENCODE_MAJOR_VERSION" -lt 2 ]]; then
        if opencode1_should_add_default_agent; then
            AGENT_LAUNCH_ARGS=(--agent build "${AGENT_ARGS[@]}")
        else
            AGENT_LAUNCH_ARGS=("${AGENT_ARGS[@]}")
        fi
    else
        build_opencode2_launch_args
    fi
fi

# Display configuration summary
log_info "\n${GREEN}=== AI Coding Agent Sandbox Configuration ===${NC}"
if [[ "$AGENT" = "opencode" && -n "$OPENCODE_MAJOR_VERSION" ]]; then
    log_info "Agent: ${YELLOW}$AGENT${NC} (major version $OPENCODE_MAJOR_VERSION)"
else
    log_info "Agent: ${YELLOW}$AGENT${NC}"
fi
if [[ "$DRY_RUN" = false ]]; then
    log_info "Agent Command: ${YELLOW}$(basename "$AGENT_BIN")${AGENT_LAUNCH_ARGS[*]:+ ${AGENT_LAUNCH_ARGS[*]}}${NC}"
fi
if [[ "$PROFILE" = "default" ]]; then
    log_info "Profile: ${YELLOW}default${NC} (host configuration, from $PROFILE_SOURCE)"
else
    log_info "Profile: ${YELLOW}$PROFILE${NC} (from $PROFILE_SOURCE) -> $PROFILE_HOME"
fi
log_info "Working Directory: ${YELLOW}$WORKING_DIR${NC}"
case "$NETWORK_MODE" in
    isolated)
        NETWORK_SUMMARY="isolated"
        [[ ${#NETWORK_HOST_PORTS[@]} -gt 0 ]] && NETWORK_SUMMARY+=", host ports: ${NETWORK_HOST_PORTS[*]}"
        [[ ${#NETWORK_ALLOW_HOSTS[@]} -gt 0 ]] && NETWORK_SUMMARY+=", allowed hosts: ${NETWORK_ALLOW_HOSTS[*]}"
        log_info "Network: ${YELLOW}$NETWORK_SUMMARY${NC} (from $NETWORK_MODE_SOURCE)"
        if [[ "$ENABLE_DOCKER" = true ]]; then
            log_info "  ${YELLOW}⚠${NC} Ports published by containers are on the host loopback: list them in host_ports or use --network host"
        fi
        ;;
    host)
        log_info "Network: ${YELLOW}host${NC} (full access, from $NETWORK_MODE_SOURCE)"
        if [[ ${#NETWORK_HOST_PORTS[@]} -gt 0 || ${#NETWORK_ALLOW_HOSTS[@]} -gt 0 ]]; then
            log_info "  ${YELLOW}⚠${NC} host_ports/allow_hosts only apply to network: isolated"
        fi
        ;;
    none)
        log_info "Network: ${YELLOW}none${NC} (from $NETWORK_MODE_SOURCE)"
        ;;
esac
if [[ ${#GIT_LINKED_DIRS[@]} -gt 0 ]]; then
    log_info "Linked Git Directories: ${YELLOW}${GIT_LINKED_DIRS[*]}${NC}"
fi
if [[ "$PROTECT_PROJECT_CONFIG" = true ]]; then
    log_info "Project Config Protection: ${YELLOW}enabled${NC} (.ai-agent-sandbox/ is read-only)"
else
    log_info "Project Config Protection: ${YELLOW}disabled${NC}"
fi
if [[ "$ENABLE_VENV" = true ]]; then
    log_info "Virtual Environment: ${YELLOW}$VENV_PATH${NC}"
else
    log_info "Virtual Environment: ${YELLOW}disabled${NC}"
fi
if [[ "$ENABLE_GPG_AGENT" = true ]]; then
    log_info "GPG Agent Forwarding: ${YELLOW}enabled${NC} ($GPG_HOST_EXTRA_SOCKET)"
else
    log_info "GPG Agent Forwarding: ${YELLOW}disabled${NC}"
fi
log_info "Config Files (${#CONFIG_FILES_LOADED[@]}):"
for cfile in "${CONFIG_FILES_LOADED[@]}"; do
    log_info "  ${YELLOW}$cfile${NC}"
done
LEGACY_FILES_IN_USE=("${WHITELIST_FILES[@]}" "${BLACKLIST_FILES[@]}" "${ENV_FILES[@]}")
if [[ ${#LEGACY_FILES_IN_USE[@]} -gt 0 ]]; then
    log_info "Deprecated Legacy Files (${#LEGACY_FILES_IN_USE[@]}):"
    for lfile in "${LEGACY_FILES_IN_USE[@]}"; do
        log_info "  ${YELLOW}$lfile${NC}"
    done
fi
log_info "Direct Environment Variables: ${YELLOW}${#ENV_VARS[@]}${NC}"
log_info "${GREEN}=============================================${NC}\n"

# Start socket proxy if Docker is enabled
if [[ "$ENABLE_DOCKER" = true ]]; then
    start_socket_proxy
fi

# Execute agent or bash (for dry-run) in sandbox
sandbox_status=0
if [[ "$DRY_RUN" = true ]]; then
    log_info "${YELLOW}=== DRY RUN MODE: Starting bash shell in sandbox ===${NC}\n"
    run_in_sandbox /bin/bash || sandbox_status=$?
else
    run_in_sandbox "$AGENT_BIN" "${AGENT_LAUNCH_ARGS[@]}" || sandbox_status=$?
fi

exit "$sandbox_status"
