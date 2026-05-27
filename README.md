# AI Agent Sandbox Script

A secure bubblewrap-based sandboxing solution for running AI coding agents with strict filesystem isolation.

## Features

- ✅ **Whitelist-based filesystem access** - Only explicitly allowed paths are readable
- ✅ **Blacklist protection** - Block sensitive files within working directory
- ✅ **Full network access** - Both local and internet access enabled
- ✅ **Configurable environment** - Optional `.env` files and direct variables, no SSH agent access
- ✅ **Virtualenv support** - Optionally expose the active Python virtual environment
- ✅ **Working directory isolation** - Full read-write only in current directory

## Requirements

- **bubblewrap** - Install with:
  - Debian/Ubuntu: `sudo apt install bubblewrap`
  - Fedora: `sudo dnf install bubblewrap`
  - Arch: `sudo pacman -S bubblewrap`
- **An AI coding agent** - Claude Code or OpenCode are currently supported

## Installation

1. Make the script executable:
```bash
chmod +x ai-agent-sandbox.sh
```

2. (Optional) Move to a directory in your PATH:
```bash
sudo mv ai-agent-sandbox.sh /usr/local/bin/ai-agent-sandbox
```

3. Create configuration directory:
```bash
mkdir -p ~/.config/ai-agent-sandbox
```

4. Copy and customize the whitelist and blacklist files:
```bash
cp whitelist-example.txt ~/.config/ai-agent-sandbox/whitelist.txt
cp blacklist-example.txt ~/.config/ai-agent-sandbox/blacklist.txt
```

5. Edit the files to match your needs:
```bash
nano ~/.config/ai-agent-sandbox/whitelist.txt
nano ~/.config/ai-agent-sandbox/blacklist.txt
```

## Usage

### Basic usage:
```bash
./ai-agent-sandbox.sh
```

### Custom whitelist/blacklist:
```bash
# Single custom file (default file is still included)
./ai-agent-sandbox.sh \
  --whitelist /path/to/my-whitelist.txt \
  --blacklist /path/to/my-blacklist.txt

# Multiple whitelist/blacklist files
./ai-agent-sandbox.sh \
  --whitelist ~/shared-whitelist.txt \
  --whitelist ./project-whitelist.txt \
  --blacklist ~/shared-blacklist.txt \
  --blacklist ./project-blacklist.txt
```

**Note:** The default whitelist and blacklist files (`~/.config/ai-agent-sandbox/{whitelist,blacklist}.txt`) are always included automatically. Additional files specified via `--whitelist` and `--blacklist` are merged with the defaults.

### Environment variables:
```bash
# Set a variable directly for this run
./ai-agent-sandbox.sh --env API_TOKEN=secret

# Short form can be repeated
./ai-agent-sandbox.sh -e API_TOKEN=secret -e FEATURE_FLAG=true

# Add one or more dotenv files
./ai-agent-sandbox.sh --env-path /path/to/.env
```

Environment files are optional. If present, `~/.config/ai-agent-sandbox/.env` and `.ai-agent-sandbox/.env` are included automatically, and additional files from `--env-path` are merged with them. Direct `--env/-e` entries are applied last.

### Python virtual environments:
```bash
# Activate a venv in your shell first
source .venv/bin/activate

# Expose the venv inside the sandbox and prepend its bin directory to PATH
./ai-agent-sandbox.sh --venv
```

`--venv` detects the active Python virtual environment from `VIRTUAL_ENV`, mounts the venv read-only, sets `VIRTUAL_ENV` inside the sandbox, and prepends `$VIRTUAL_ENV/bin` to `PATH`. If no active venv is detected, the option is ignored.

### Pass arguments to the selected agent:
```bash
./ai-agent-sandbox.sh -- --model claude-sonnet-4-5
```

### Docker support (Testcontainers)
```bash
# Enable Docker access via filtered socket proxy (long or short flag)
./ai-agent-sandbox.sh -d

# Add writable caches for dependency downloads
./ai-agent-sandbox.sh \
  -d \
  --whitelist-path-rw ~/.m2/repository \
  --whitelist-path-rw ~/.gradle/caches
```

Docker access is provided through a per-run socket proxy created at `.docker-proxy/docker.sock` in the working directory. The proxy only allows bind mounts from paths already accessible inside the sandbox (working directory and any read-write mounts).

### Using environment variables:
```bash
export AI_AGENT_SANDBOX_WHITELIST=/path/to/whitelist.txt
export AI_AGENT_SANDBOX_BLACKLIST=/path/to/blacklist.txt
export AI_AGENT_SANDBOX_ENV=/path/to/.env
./ai-agent-sandbox.sh
```

## Configuration

### Multiple Configuration Files

The script supports **multiple whitelist, blacklist, and environment files**, which are processed in order:

1. **User-level files** (always included if they exist):
   - `~/.config/ai-agent-sandbox/whitelist.txt`
   - `~/.config/ai-agent-sandbox/blacklist.txt`
   - `~/.config/ai-agent-sandbox/.env`
   - Whitelist and blacklist files are auto-generated if they don't exist and no explicit files are provided; `.env` is optional and never auto-generated

2. **Project-level files** (automatically included if they exist):
   - `.ai-agent-sandbox/whitelist.txt` (in working directory)
   - `.ai-agent-sandbox/blacklist.txt` (in working directory)
   - `.ai-agent-sandbox/.env` (in working directory)
   - **Never auto-generated** - create manually if needed

3. **Additional files** specified via `--whitelist`, `--blacklist`, and `--env-path` flags

All files are merged together, allowing you to:
- Maintain a base configuration in user-level files
- Add project-specific rules in `.ai-agent-sandbox/` directory (can be committed to version control)
- Override with additional files via command-line flags
- Share configurations across teams and projects

### Environment File Format

Environment files use dotenv-style `KEY=VALUE` entries:

```bash
# Comments and blank lines are ignored
API_TOKEN=secret
FEATURE_FLAG=true
QUOTED_VALUE="value with spaces"
export TOOL_HOME=/opt/tooling
```

**Important:**
- Values are exposed inside the sandbox via `bubblewrap --setenv`.
- Later entries override earlier entries when the same key appears multiple times.
- Variable names must match shell environment naming rules, such as `API_TOKEN` or `_PRIVATE`.
- Logs show variable names only, not values.

### Whitelist Format

The whitelist file contains **absolute paths or glob patterns** (one per line) that the agent can read:

```
# System binaries (read-only by default)
/usr/bin
/usr/lib

# Java tools (for Java developers) - using glob patterns
/usr/lib/jvm
/etc/java*
/etc/maven

# Maven cache with read-write access
~/.m2/repository:rw

# Custom paths with read-write for specific directory
/opt/company/shared-cache:rw

# Glob pattern with read-write
/opt/build-*:rw
```

**Important:**
- Paths must be absolute (start with `/`)
- **Read-write access**: Suffix a path with `:rw` to mount it read-write (e.g., `/path/to/dir:rw`)
  - Default: all paths are mounted read-only (safer)
  - Use `:rw` only for paths where the agent needs write access (caches, build outputs, etc.)
  - Works with both literal paths and patterns (e.g., `/opt/cache-*:rw`)
- **Blacklist override**: Prefix a path with `!` to re-allow a specific path that would otherwise be blocked by the blacklist
  - Overrides are applied after the blacklist, so they take precedence
  - Example: `!secrets/dev.key`
- **Pattern support**:
  - Simple glob: `*`, `?`, `[]` (e.g., `/etc/java*` matches `/etc/java-11`, `/etc/java-17`)
  - **Ant-style recursive**: `**` for recursive directory matching (e.g., `/usr/**/lib64` matches any `lib64` directory under `/usr`)
- Lines starting with `#` are ignored
- Environment variables like `$HOME` are expanded
- When using multiple whitelist files, all paths from all files are allowed

### Blacklist Format

The blacklist file contains **relative paths** from the working directory that the agent cannot access:

```
# Environment files
**/.env
**/.env.*

# SSH keys
**/*.pem
**/*.key
**/id_rsa
**/id_ed25519

# Cloud credentials
**/.aws
**/.gcp
```

**Important:**
- Paths are relative to the working directory
- **Pattern support**:
  - Simple glob: `*`, `?` (e.g., `*.env` matches `.env.local`, `.env.prod`)
  - **Ant-style recursive**: `**` for recursive matching (e.g., `**/wallet.dat` matches `wallet.dat` anywhere in the working directory tree)
- Trailing `/` is accepted and normalized (for example, `secret-data/` behaves like `secret-data`)
- Lines starting with `#` are ignored
- When using multiple blacklist files, all patterns from all files are blocked

### Symlink behavior

- Matching is done on paths inside the working directory, so symlink names can be matched by whitelist/blacklist patterns.
- **Whitelist**: symlink paths are allowed when they resolve to an existing target at sandbox startup.
- **Blacklist**: matched symlinks are resolved to their canonical target path.
- If the resolved blacklist target is inside the working directory, the target is hidden.
- If the resolved blacklist target is outside the working directory (or cannot be resolved), the entry is skipped.

**Examples of ant-style patterns:**
```
# Block wallet.dat anywhere in the project
**/wallet.dat

# Block all .env files recursively
**/.env

# Block all private key files anywhere
**/*.pem
**/*.key

# Block test secrets in any test directory
**/test/**/secrets.json
```

## Security Considerations

### What This Script Protects Against

1. ✅ **Filesystem access outside working directory** - Only whitelisted system paths are readable
2. ✅ **Sensitive files in working directory** - Blacklisted patterns are hidden
3. ✅ **SSH agent access** - SSH_AUTH_SOCK is removed from environment
4. ✅ **Home directory access** - Only minimal agent-specific config is exposed

### Limitations and Considerations

1. ⚠️ **Full network access** - The sandbox has complete network access (both local and internet). If you need network isolation, you'll need to modify the script to use `--unshare-net` with `slirp4netns`.

2. ⚠️ **Blacklist uses tmpfs mounts** - Files matching blacklist patterns are hidden via tmpfs. This means:
   - Glob patterns are expanded at sandbox start time
   - Performance impact is minimal

3. ⚠️ **Working directory is still read-write** - The agent has full access to create/modify/delete files in the working directory (except blacklisted ones). This is necessary for coding agents to function.

4. ⚠️ **No process isolation** - While filesystem is isolated, agent processes run on the host system (though in separate namespaces).

### Recommended Additional Hardening

For maximum security, consider:

1. **Resource limits**:
```bash
# Use systemd-run or ulimit to restrict CPU/memory
systemd-run --scope -p CPUQuota=200% -p MemoryMax=4G ./ai-agent-sandbox.sh
```

2. **Read-only working directory option**:
```bash
# For analysis tasks where the agent shouldn't modify files
# (Would need script modification to support this use case)
```

3. **Audit logging**:
```bash
# Monitor file access patterns
auditctl -w /path/to/project -p rwa
```

4. **Network isolation**:
```bash
# Modify the script to use --unshare-net with slirp4netns
# for selective internet access while blocking local networks
```

## Troubleshooting

### "bubblewrap is not installed"
Install bubblewrap using your package manager (see Requirements section).

### "agent is not installed"
Install the selected agent. Claude Code and OpenCode are currently supported.

### The agent can't access necessary system libraries
Add the required paths to your whitelist file. Common additions:
- `/usr/lib/x86_64-linux-gnu` (Debian/Ubuntu)
- `/usr/lib64` (RedHat/Fedora)
- `/opt/custom-tools`

### The agent needs to access a specific sensitive file
If you genuinely need the agent to access a file that's blacklisted:
1. Add an override entry to the whitelist (prefix with `!`), or
2. Remove it from the blacklist, or
3. Create a copy outside the blacklisted pattern

## Examples

### Using multiple configuration files

You can maintain layered configurations at different levels:

```bash
# Layer 1: User-level (~/.config/ai-agent-sandbox/whitelist.txt)
/usr/bin
/usr/lib
/usr/share

# Layer 2: Project-level (.ai-agent-sandbox/whitelist.txt in your project)
/opt/custom-compiler
/home/user/project-specific-libs

# Layer 3: Additional files via command line
ai-agent-sandbox.sh --whitelist ./team-shared-whitelist.txt
```

**Using project-level files:**
```bash
# Create project-level configuration (can be committed to git)
mkdir -p .ai-agent-sandbox
cat > .ai-agent-sandbox/whitelist.txt << EOF
/opt/project-tools
/usr/lib/project-dependencies
EOF

cat > .ai-agent-sandbox/blacklist.txt << EOF
.env.local
secrets/
*.key
EOF

# Now these files are automatically used when running in this directory
ai-agent-sandbox.sh
```

This approach allows you to:
- Keep common system paths in user-level files
- Add project-specific rules in `.ai-agent-sandbox/` (version controlled)
- Share configurations across team members
- Override with additional files when needed

### Java developer setup:
```bash
# whitelist.txt
# Java tools
/etc/java*
/etc/maven
~/.m2/repository:rw  # Maven cache (read-write so the agent can download dependencies)

# blacklist.txt
.env
application-secrets.yml
keystore.jks
```

### DevOps/Ansible/Docker setup:
```bash
# whitelist.txt
# DevOps tools
/var/run/docker.sock
/usr/libexec/docker

# blacklist.txt
.env
*vault*.yml
ansible-vault.key
inventory/production
.ssh
*.pem
```

## Contributing

Suggestions for improvements:
1. More sophisticated overlay filesystem handling
2. Integration with security audit tools
3. Preset profiles for common development stacks
4. Optional network isolation modes

## Security Disclosure

If you find security issues with this sandboxing approach, please consider responsible disclosure practices.
