#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configuration
DEFAULT_WHITELIST_FILE="${CLAUDE_SANDBOX_WHITELIST:-$HOME/.config/claude-sandbox/whitelist.txt}"
DEFAULT_BLACKLIST_FILE="${CLAUDE_SANDBOX_BLACKLIST:-$HOME/.config/claude-sandbox/blacklist.txt}"
DEFAULT_ENV_FILE="${CLAUDE_SANDBOX_ENV:-$HOME/.config/claude-sandbox/.env}"
WORKING_DIR="$(pwd)"
PROJECT_WHITELIST_FILE="$WORKING_DIR/.claude/whitelist.txt"
PROJECT_BLACKLIST_FILE="$WORKING_DIR/.claude/blacklist.txt"
PROJECT_ENV_FILE="$WORKING_DIR/.claude/.env"
WHITELIST_FILES=()
BLACKLIST_FILES=()
ENV_FILES=()
WHITELIST_PATHS_RO=()
WHITELIST_PATHS_RW=()
BLACKLIST_PATHS=()
ENV_VARS=()
BLACKLISTED_DIRS=()
BLACKLIST_SEARCH_ROOTS=()
WHITELIST_OVERRIDE_ARGS=()
EXPLICIT_WHITELIST=false
EXPLICIT_BLACKLIST=false
QUIET=false
DRY_RUN=false
AGENT="claudecode"
ENABLE_DOCKER=false
SOCKET_PROXY_IMAGE="${CLAUDE_SANDBOX_DOCKER_PROXY:-ghcr.io/wollomatic/socket-proxy:1}"
PROXY_CONTAINER_NAME=""
PROXY_SOCKET_PATH=""
PROXY_SOCKET_DIR=""

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [-- AGENT_ARGS...]

Securely run AI coding agents in a sandboxed environment using bubblewrap.

OPTIONS:
    --agent, -a AGENT      AI coding agent to use: claudecode (default) or opencode
    --whitelist FILE        Add whitelist file (can be specified multiple times)
    --blacklist FILE        Add blacklist file (can be specified multiple times)
    --env-path FILE         Add environment file (can be specified multiple times)
    --env, -e KEY=VALUE     Set environment variable inside sandbox (can be specified multiple times)
    --whitelist-path PATH   Directly whitelist a path (read-only, can be specified multiple times)
    --whitelist-path-rw PATH Directly whitelist a path (read-write, can be specified multiple times)
    --blacklist-path PATH   Directly blacklist a path (relative to working dir, can be specified multiple times)
    --enable-docker, -d     Enable Docker access via filtered socket proxy
    --docker-image IMAGE    Socket proxy image (default: ghcr.io/wollomatic/socket-proxy:1)
    --dry-run              Start bash shell instead of agent (for testing)
    --quiet, -q            Suppress informational output (faster startup)
    --verbose, -v          Show detailed output (default)
    -h, --help             Show this help message

IMPLICIT CONFIGURATION FILES (automatically included if they exist):
    1. User-level (always):
       - $DEFAULT_WHITELIST_FILE
       - $DEFAULT_BLACKLIST_FILE
       - $DEFAULT_ENV_FILE
    2. Project-level (if present):
       - .claude/whitelist.txt (in working directory)
       - .claude/blacklist.txt (in working directory)
       - .claude/.env (in working directory)

CONFIGURATION FILE FORMAT:
    Whitelist: Contains absolute or relative paths/patterns (one per line) that Claude can read
                Relative paths are resolved relative to working directory
                Default: read-only bind mount
                Suffix with :rw for read-write bind (e.g., /path/to/dir:rw or data/:rw)
                Supports glob patterns: /etc/java* or src/** will expand to all matching paths
                Prefix with ! to override blacklist for a specific path (applied after blacklist)
    Blacklist: Contains paths relative to working directory that Claude cannot access
    Env:       Contains KEY=VALUE entries to expose inside the sandbox

EXAMPLES:
    $0
    $0 --agent opencode
    $0 --whitelist /path/to/custom-whitelist.txt
    $0 --whitelist file1.txt --whitelist file2.txt
    $0 --env-path /path/to/.env
    $0 --env API_TOKEN=secret
    $0 --whitelist-path /var/run/docker.sock
    $0 --whitelist-path-rw /shared/data
    $0 --blacklist-path .env --blacklist-path secrets/
    $0 -- --model claude-sonnet-4-5
    $0 -a opencode -- --model deepseek-chat

EOF
    exit 1
}

# Parse command line arguments
AGENT_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --whitelist)
            WHITELIST_FILES+=("$2")
            EXPLICIT_WHITELIST=true
            shift 2
            ;;
        --blacklist)
            BLACKLIST_FILES+=("$2")
            EXPLICIT_BLACKLIST=true
            shift 2
            ;;
        --env-path)
            ENV_FILES+=("$2")
            shift 2
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
        --docker-image)
            SOCKET_PROXY_IMAGE="$2"
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

# Helper function for conditional output
log_info() {
    [[ "$QUIET" = false ]] && echo -e "$@" >&2
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

    if ! docker image inspect "$SOCKET_PROXY_IMAGE" &>/dev/null; then
        log_info "${YELLOW}Socket proxy image not found, pulling: $SOCKET_PROXY_IMAGE${NC}"
        if ! docker pull "$SOCKET_PROXY_IMAGE" >/dev/null; then
            echo -e "${RED}Error: Failed to pull socket proxy image${NC}" >&2
            exit 1
        fi
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

    # Add read-write bind mounts from bubblewrap args
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
    PROXY_CONTAINER_NAME="claude-sandbox-proxy-$$"
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

# Shells conventionally report signal termination as 128 + signal number.
SIGHUP_SIGNAL=1
SIGTERM_SIGNAL=15
SIGHUP_EXIT_STATUS=$((128 + SIGHUP_SIGNAL))
SIGTERM_EXIT_STATUS=$((128 + SIGTERM_SIGNAL))

trap cleanup_socket_proxy EXIT
trap 'exit "$SIGHUP_EXIT_STATUS"' HUP
trap 'exit "$SIGTERM_EXIT_STATUS"' TERM

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

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

parse_env_assignment() {
    local line="$1"
    local key_ref="$2"
    local value_ref="$3"
    local env_key
    local env_value

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
    else
        env_value="${env_value%%[[:space:]]#*}"
        env_value=$(trim_whitespace "$env_value")
    fi

    printf -v "$key_ref" '%s' "$env_key"
    printf -v "$value_ref" '%s' "$env_value"
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

    BWRAP_ARGS+=(--setenv "$key" "$value")
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
        # Extract the filename part after the last **
        if [[ "$pattern" =~ \*\*/([^/]+)$ ]]; then
            # Pattern like **/wallet.dat or src/**/wallet.dat
            local filename="${BASH_REMATCH[1]}"
            find_args=(-name "$filename")
        else
            # Complex pattern like src/**/test/**/*.java
            # Convert ** to */ for path matching
            local path_pattern="${pattern//\*\*/\*}"
            find_args=(-path "$base_dir/$path_pattern")
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

# Validate agent selection
if [[ "$AGENT" != "claudecode" ]] && [[ "$AGENT" != "opencode" ]]; then
    echo -e "${RED}Error: Invalid agent '$AGENT'. Must be 'claudecode' or 'opencode'${NC}" >&2
    exit 1
fi

validate_docker

# Cache command availability checks
BWRAP_BIN=$(command -v bwrap 2>/dev/null)

# Check if bubblewrap is installed
if [[ -z "$BWRAP_BIN" ]]; then
    echo -e "${RED}Error: bubblewrap (bwrap) is not installed${NC}" >&2
    echo "Install it with: sudo apt install bubblewrap (Debian/Ubuntu) or sudo dnf install bubblewrap (Fedora)" >&2
    exit 1
fi

# Detect agent binary based on selection
if [[ "$AGENT" = "claudecode" ]]; then
    AGENT_BIN=$(command -v claude 2>/dev/null)
    if [[ -z "$AGENT_BIN" ]]; then
        echo -e "${RED}Error: claude is not installed${NC}" >&2
        echo "Install it from: https://docs.claude.com/en/docs/claude-code" >&2
        exit 1
    fi
elif [[ "$AGENT" = "opencode" ]]; then
    AGENT_BIN="$HOME/.opencode/bin/opencode"
    if [[ ! -x "$AGENT_BIN" ]]; then
        echo -e "${RED}Error: opencode is not installed at $AGENT_BIN${NC}" >&2
        echo "Install it from: https://opencode.dev" >&2
        exit 1
    fi
fi

# Create default whitelist if it doesn't exist and no explicit whitelist was given
if [[ ! -f "$DEFAULT_WHITELIST_FILE" ]] && [[ "$EXPLICIT_WHITELIST" = false ]]; then
    echo -e "${YELLOW}Warning: Whitelist file not found at $DEFAULT_WHITELIST_FILE${NC}" >&2
    echo -e "${YELLOW}Creating default whitelist...${NC}" >&2
    mkdir -p "$(dirname "$DEFAULT_WHITELIST_FILE")"
    cat > "$DEFAULT_WHITELIST_FILE" << 'EOWHITELIST'
# Claude Code Sandbox Whitelist
# Add absolute paths (one per line) that Claude should be able to read
# Lines starting with # are ignored

# Essential system directories
/usr/bin
/usr/lib
/usr/lib64
/usr/share
/lib
/lib64
/bin
/sbin

# Common development tools locations
/usr/local/bin
/usr/local/lib

# System configuration that's generally safe
/etc/alternatives
/etc/ssl/certs

EOWHITELIST
    echo -e "${GREEN}Created default whitelist at $DEFAULT_WHITELIST_FILE${NC}" >&2
    echo -e "${YELLOW}Please review and customize it for your needs${NC}" >&2
fi

# Create default blacklist if it doesn't exist and no explicit blacklist was given
if [[ ! -f "$DEFAULT_BLACKLIST_FILE" ]] && [[ "$EXPLICIT_BLACKLIST" = false ]]; then
    echo -e "${YELLOW}Warning: Blacklist file not found at $DEFAULT_BLACKLIST_FILE${NC}" >&2
    echo -e "${YELLOW}Creating default blacklist...${NC}" >&2
    mkdir -p "$(dirname "$DEFAULT_BLACKLIST_FILE")"
    cat > "$DEFAULT_BLACKLIST_FILE" << 'EOBLACKLIST'
# Claude Code Sandbox Blacklist
# Add paths relative to working directory that Claude should NOT access
# Lines starting with # are ignored

# Common sensitive files
**/.env

# SSH and crypto keys
**/.ssh
**/*.pem
**/*.key
**/id_rsa
**/id_ed25519
**/*.p12
**/*.pfx

# AWS credentials
**/.aws/credentials

# Docker and Kubernetes secrets
**/docker-compose.override.yml
**/.kube/config

# Password managers
**/*.kdbx
**/*.agilekeychain
**/.vault_password

EOBLACKLIST
    echo -e "${GREEN}Created default blacklist at $DEFAULT_BLACKLIST_FILE${NC}" >&2
    echo -e "${YELLOW}Please review and customize it for your needs${NC}" >&2
fi

# Always include default files in the arrays (at the beginning)
if [[ -f "$DEFAULT_WHITELIST_FILE" ]]; then
    WHITELIST_FILES=("$DEFAULT_WHITELIST_FILE" "${WHITELIST_FILES[@]}")
fi
if [[ -f "$DEFAULT_BLACKLIST_FILE" ]]; then
    BLACKLIST_FILES=("$DEFAULT_BLACKLIST_FILE" "${BLACKLIST_FILES[@]}")
fi
if [[ -f "$DEFAULT_ENV_FILE" ]]; then
    ENV_FILES=("$DEFAULT_ENV_FILE" "${ENV_FILES[@]}")
fi

# Include project-level files if they exist (after default, before explicit)
if [[ -f "$PROJECT_WHITELIST_FILE" ]]; then
    WHITELIST_FILES+=("$PROJECT_WHITELIST_FILE")
fi
if [[ -f "$PROJECT_BLACKLIST_FILE" ]]; then
    BLACKLIST_FILES+=("$PROJECT_BLACKLIST_FILE")
fi
if [[ -f "$PROJECT_ENV_FILE" ]]; then
    ENV_FILES+=("$PROJECT_ENV_FILE")
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

# Process all whitelist files and add to bubblewrap (after tmpfs so HOME paths work)
if [[ ${#WHITELIST_FILES[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No whitelist files found${NC}" >&2
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

        read -r override line < <(parse_whitelist_override "$line")
        [[ -z "$line" ]] && continue

        # Check for read-write suffix (:rw)
        bind_mode="ro"
        if [[ "$line" =~ :rw$ ]]; then
            bind_mode="rw"
            line="${line%:rw}"  # Strip :rw suffix
        fi

        # Process the path using the helper function
        if [[ "$override" = "true" ]]; then
            whitelist_path "$line" "$bind_mode" "WHITELIST_OVERRIDE_ARGS" "Whitelisted (override)"
        else
            whitelist_path "$line" "$bind_mode" "BWRAP_ARGS" "Whitelisted"
        fi
    done < "$WHITELIST_FILE"
done

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

log_info "\n${YELLOW}Agent-specific configuration bindings:"
if [[ "$AGENT" = "claudecode" ]]; then
    # Bind claude binary
    if [[ -e "$HOME/.local/bin/claude" ]]; then
        # If it's a symlink, we need to bind the target first, then create the symlink
        if [[ -L "$HOME/.local/bin/claude" ]]; then
            CLAUDE_TARGET=$(readlink -f "$HOME/.local/bin/claude")
            if [[ -f "$CLAUDE_TARGET" ]]; then
                # Bind the actual binary/target
                BWRAP_ARGS+=(--ro-bind "$CLAUDE_TARGET" "$CLAUDE_TARGET")
                # Create a symlink in the sandbox
                BWRAP_ARGS+=(--symlink "${CLAUDE_TARGET}" "$HOME/.local/bin/claude")
                log_info "${GREEN}✓${NC} Mounted $CLAUDE_TARGET and created symlink at ~/.local/bin/claude (read-only)"
            fi
        elif [[ -x "$HOME/.local/bin/claude" ]]; then
            # It's a regular file, bind it directly
            BWRAP_ARGS+=(--ro-bind "$HOME/.local/bin/claude" "$HOME/.local/bin/claude")
            log_info "${GREEN}✓${NC} Mounted ~/.local/bin/claude (read-only)"
        fi
    fi

    # Bind ~/.claude directory (main config location)
    if [[ -d "$HOME/.claude" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.claude" "$HOME/.claude")
        log_info "${GREEN}✓${NC} Mounted ~/.claude (read-write)"
    fi

    # Bind ~/.claude.json file (state file in home directory)
    if [[ -f "$HOME/.claude.json" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.claude.json" "$HOME/.claude.json")
        log_info "${GREEN}✓${NC} Mounted ~/.claude.json (read-write)"
    else
        # Create empty file if it doesn't exist so Claude can write to it
        touch "$HOME/.claude.json"
        BWRAP_ARGS+=(--bind "$HOME/.claude.json" "$HOME/.claude.json")
        log_info "${YELLOW}✓${NC} Created and mounted ~/.claude.json (read-write)"
    fi

    # Bind ~/.claude.json.backup if it exists
    if [[ -f "$HOME/.claude.json.backup" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.claude.json.backup" "$HOME/.claude.json.backup")
    fi
elif [[ "$AGENT" = "opencode" ]]; then
    # Bind opencode binary and directory
    if [[ -d "$HOME/.opencode" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.opencode" "$HOME/.opencode")
        log_info "${GREEN}✓${NC} Mounted ~/.opencode (read-write)"
    fi

    # Bind ~/.opencode.json file (state file in home directory)
    if [[ -f "$HOME/.opencode.json" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.opencode.json" "$HOME/.opencode.json")
        log_info "${GREEN}✓${NC} Mounted ~/.opencode.json (read-write)"
    else
        # Create empty file if it doesn't exist so opencode can write to it
        touch "$HOME/.opencode.json"
        BWRAP_ARGS+=(--bind "$HOME/.opencode.json" "$HOME/.opencode.json")
        log_info "${YELLOW}✓${NC} Created and mounted ~/.opencode.json (read-write)"
    fi

    # Bind XDG directories for OpenCode (settings, cache, state, data)
    # OpenCode follows XDG Base Directory Specification
    if [[ -d "$HOME/.config/opencode" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.config/opencode" "$HOME/.config/opencode")
        log_info "${GREEN}✓${NC} Mounted ~/.config/opencode (read-write)"
    else
        mkdir -p "$HOME/.config/opencode"
        BWRAP_ARGS+=(--bind "$HOME/.config/opencode" "$HOME/.config/opencode")
        log_info "${YELLOW}✓${NC} Created and mounted ~/.config/opencode (read-write)"
    fi

    if [[ -d "$HOME/.cache/opencode" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.cache/opencode" "$HOME/.cache/opencode")
        log_info "${GREEN}✓${NC} Mounted ~/.cache/opencode (read-write)"
    else
        mkdir -p "$HOME/.cache/opencode"
        BWRAP_ARGS+=(--bind "$HOME/.cache/opencode" "$HOME/.cache/opencode")
        log_info "${YELLOW}✓${NC} Created and mounted ~/.cache/opencode (read-write)"
    fi

    if [[ -d "$HOME/.local/state/opencode" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.local/state/opencode" "$HOME/.local/state/opencode")
        log_info "${GREEN}✓${NC} Mounted ~/.local/state/opencode (read-write)"
    else
        mkdir -p "$HOME/.local/state/opencode"
        BWRAP_ARGS+=(--bind "$HOME/.local/state/opencode" "$HOME/.local/state/opencode")
        log_info "${YELLOW}✓${NC} Created and mounted ~/.local/state/opencode (read-write)"
    fi

    if [[ -d "$HOME/.local/share/opencode" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.local/share/opencode" "$HOME/.local/share/opencode")
        log_info "${GREEN}✓${NC} Mounted ~/.local/share/opencode (read-write)"
    else
        mkdir -p "$HOME/.local/share/opencode"
        BWRAP_ARGS+=(--bind "$HOME/.local/share/opencode" "$HOME/.local/share/opencode")
        log_info "${YELLOW}✓${NC} Created and mounted ~/.local/share/opencode (read-write)"
    fi
fi

BWRAP_ARGS+=(--setenv HOME "$HOME")
BWRAP_ARGS+=(--setenv PWD "$WORKING_DIR")
BWRAP_ARGS+=(--chdir "$WORKING_DIR")

# Network configuration - allow all network access
log_info "\n${GREEN}Network: Full access enabled (local and internet)${NC}"

# Share the network namespace to allow all network access
BWRAP_ARGS+=(--share-net)

# Use system DNS configuration
if [[ -f /etc/resolv.conf ]]; then
    BWRAP_ARGS+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
fi

# Bind /etc/hosts for name resolution
if [[ -f /etc/hosts ]]; then
    BWRAP_ARGS+=(--ro-bind /etc/hosts /etc/hosts)
fi

# Set minimal environment
BWRAP_ARGS+=(--setenv TERM "${TERM:-xterm-256color}")
if [[ "$AGENT" = "claudecode" ]]; then
    BWRAP_ARGS+=(--setenv PATH "$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin")
elif [[ "$AGENT" = "opencode" ]]; then
    BWRAP_ARGS+=(--setenv PATH "$HOME/.opencode/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin")
fi
BWRAP_ARGS+=(--unsetenv SSH_AUTH_SOCK)
BWRAP_ARGS+=(--unsetenv SSH_AGENT_PID)

if [[ "$ENABLE_DOCKER" = true ]]; then
    BWRAP_ARGS+=(--setenv DOCKER_HOST "unix://$WORKING_DIR/.docker-proxy/docker.sock")
    BWRAP_ARGS+=(--setenv TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE "$WORKING_DIR/.docker-proxy/docker.sock")
    BWRAP_ARGS+=(--setenv TESTCONTAINERS_HOST_OVERRIDE "localhost")
fi

# Preserve agent-specific environment variables
if [[ "$AGENT" = "claudecode" ]]; then
    if [[ -n "${CLAUDECODE:-}" ]]; then
        BWRAP_ARGS+=(--setenv CLAUDECODE "$CLAUDECODE")
    fi
    if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
        BWRAP_ARGS+=(--setenv CLAUDE_CODE_ENTRYPOINT "$CLAUDE_CODE_ENTRYPOINT")
    fi
elif [[ "$AGENT" = "opencode" ]]; then
    # Force YOLO-style permissions inside sandboxed OpenCode runs.
    BWRAP_ARGS+=(--setenv OPENCODE_PERMISSION '{"*":"allow"}')
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

# Display configuration summary
log_info "\n${GREEN}=== AI Coding Agent Sandbox Configuration ===${NC}"
log_info "Agent: ${YELLOW}$AGENT${NC}"
log_info "Working Directory: ${YELLOW}$WORKING_DIR${NC}"
log_info "Whitelist Files (${#WHITELIST_FILES[@]}):"
for wfile in "${WHITELIST_FILES[@]}"; do
    log_info "  ${YELLOW}$wfile${NC}"
done
log_info "Blacklist Files (${#BLACKLIST_FILES[@]}):"
for bfile in "${BLACKLIST_FILES[@]}"; do
    log_info "  ${YELLOW}$bfile${NC}"
done
log_info "Environment Files (${#ENV_FILES[@]}):"
for efile in "${ENV_FILES[@]}"; do
    log_info "  ${YELLOW}$efile${NC}"
done
log_info "Direct Environment Variables: ${YELLOW}${#ENV_VARS[@]}${NC}"
log_info "${GREEN}=============================================${NC}\n"

# Start socket proxy if Docker is enabled
if [[ "$ENABLE_DOCKER" = true ]]; then
    start_socket_proxy
fi

# Build default agent args (prepended before user args)
DEFAULT_AGENT_ARGS=()
if [[ "$AGENT" = "claudecode" ]]; then
    DEFAULT_AGENT_ARGS+=(--dangerously-skip-permissions)
elif [[ "$AGENT" = "opencode" ]]; then
    DEFAULT_AGENT_ARGS+=(--agent build)
fi

# Execute agent or bash (for dry-run) in sandbox
sandbox_status=0
if [[ "$DRY_RUN" = true ]]; then
    log_info "${YELLOW}=== DRY RUN MODE: Starting bash shell in sandbox ===${NC}\n"
    "$BWRAP_BIN" "${BWRAP_ARGS[@]}" -- /bin/bash || sandbox_status=$?
else
    "$BWRAP_BIN" "${BWRAP_ARGS[@]}" -- "$AGENT_BIN" "${DEFAULT_AGENT_ARGS[@]}" "${AGENT_ARGS[@]}" || sandbox_status=$?
fi

exit "$sandbox_status"
