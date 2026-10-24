# AI Agent Sandbox Script

A secure bubblewrap-based sandboxing solution for running AI coding agents with strict filesystem isolation.

## Features

- ✅ **Whitelist-based filesystem access** - Only explicitly allowed paths are readable
- ✅ **Blacklist protection** - Block sensitive files within working directory
- ✅ **Network isolation** - Internet access through user-mode networking, while the host's loopback services and private networks stay hidden (`--network host` for full access)
- ✅ **Configurable environment** - Variables from `config.yaml` or the command line, no SSH agent access
- ✅ **Virtualenv support** - Optionally expose the active Python virtual environment
- ✅ **Working directory isolation** - Full read-write only in current directory
- ✅ **Named profiles** - Separate agent logins, settings and memory per profile (work, client, private)
- ✅ **Project configuration file** - `.ai-agent-sandbox/config.yaml` pins the profile and other options per project

## Requirements

- **bubblewrap** - Install with:
  - Debian/Ubuntu: `sudo apt install bubblewrap`
  - Fedora: `sudo dnf install bubblewrap`
  - Arch: `sudo pacman -S bubblewrap`
- **passt** (provides `pasta`, optional but used by the default network mode) - Install with:
  - Debian/Ubuntu: `sudo apt install passt`
  - Fedora: `sudo dnf install passt`
  - Arch: `sudo pacman -S passt`
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

3. Run it once. On the first run a default `~/.config/ai-agent-sandbox/config.yaml` with a basic whitelist and blacklist is created. Review and customize it:
```bash
nano ~/.config/ai-agent-sandbox/config.yaml
```

   Alternatively, start from the commented example of every key:
```bash
mkdir -p ~/.config/ai-agent-sandbox
cp config-example.yaml ~/.config/ai-agent-sandbox/config.yaml
```

## Usage

### Basic usage:
```bash
./ai-agent-sandbox.sh
```

### Custom whitelist/blacklist:
Whitelist and blacklist entries live in the `whitelist:` and `blacklist:` lists of the [config files](#configuration-file-configyaml). For a single run, add paths on the command line:
```bash
./ai-agent-sandbox.sh \
  --whitelist-path /opt/tools \
  --whitelist-path-rw ~/.m2/repository \
  --blacklist-path secrets/
```

Entries from the command line are merged with those from the config files.

### Environment variables:
```bash
# Set a variable directly for this run
./ai-agent-sandbox.sh --env API_TOKEN=secret

# Short form can be repeated
./ai-agent-sandbox.sh -e API_TOKEN=secret -e FEATURE_FLAG=true
```

Permanent variables belong in the `env:` mapping of the config files. Direct `--env/-e` entries are applied after them.

### Python virtual environments:
```bash
# Activate a venv in your shell first
source .venv/bin/activate

# Expose the venv inside the sandbox and prepend its bin directory to PATH
./ai-agent-sandbox.sh --venv
```

`--venv` detects the active Python virtual environment from `VIRTUAL_ENV`, mounts the venv read-only, sets `VIRTUAL_ENV` inside the sandbox, and prepends `$VIRTUAL_ENV/bin` to `PATH`. If no active venv is detected, the option is ignored.

### Network isolation:

By default the sandbox runs in its own network namespace. [pasta](https://passt.top/) attaches user-mode networking to it, so the agent reaches the internet transparently (no proxy settings, every tool works), while:

- the host's loopback is **not** reachable: a database, Docker port or control plane listening on `localhost` on the host is invisible unless you forward it;
- private networks are **blocked**: `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`, `fc00::/7`, `fe80::/10` and every subnet the host itself is attached to (also when it has public addresses);
- ports the agent binds inside (dev servers, test fixtures) are published on the host as before, so your browser still reaches `localhost:3000`;
- Unix sockets (Docker proxy, GPG agent) are unaffected.

```bash
# T3 Code's MCP server, a database published by Docker: reachable at localhost inside
./ai-agent-sandbox.sh --host-port 3773 --host-port 5432

# A machine on the LAN (IP, CIDR range or hostname resolved at start)
./ai-agent-sandbox.sh --allow-host 192.168.1.50 --allow-host 10.0.0.0/24 --allow-host nas.local

# Full host network as before, or no network at all (offline test runs)
./ai-agent-sandbox.sh --network host
./ai-agent-sandbox.sh --network none
```

The same settings exist as config keys (`network`, `host_ports`, `allow_hosts`) in user and project files and as the environment variable `AI_AGENT_SANDBOX_NETWORK`. A project may switch itself to `network: host`; the startup summary shows where the mode came from.

Requirements: `pasta` (package `passt`), `nsenter` (util-linux) and `ip` (iproute2) on the host. Without them the default mode falls back to the host network with a warning; an explicitly requested `isolated` mode fails instead.

Limits: LAN machines with public IP addresses on subnets the host is not directly attached to are indistinguishable from the internet. Blocking the internet itself is pointless, the agent talks to its LLM provider anyway. With `--enable-docker`, containers' published ports live on the host loopback, so list them in `host_ports` (or use `--network host`); the `172.17.x` bridge addresses are blocked.

### Git configuration:

By default, `~/.gitconfig` is mounted read-only into the sandbox (if it exists) so git identity and settings (user name, email, aliases) work inside. To disable this:

```bash
./ai-agent-sandbox.sh --no-gitconfig
```

### Git worktrees:

A git worktree (`git worktree add ../feature`) has a `.git` *file* that points into the main repository, which usually lies outside the working directory. The sandbox follows that link and mounts the main repository's `.git` directory read-write at its own path, so `git status`, `git commit` and friends work inside the worktree. Nothing happens for a normal checkout. The mounted directory is listed in the startup summary as `Linked Git Directories`. This exposes exactly what a normal checkout already exposes through its own `.git` (hooks, config), nothing more.

The `.git` file is writable by the agent, so it is not trusted on its own: the link is followed only when the target is a `<repo>/.git/worktrees/<name>` directory whose `gitdir` back-link (written by git) points at this working tree's `.git` file and whose `commondir` matches. An agent that rewrites `.git` or `commondir` to name some other directory gets a warning on the next start, not a mount. Checkouts with a separate git dir (`--separate-git-dir`) and submodules have no such back-link and are not followed; add their git dir with `--whitelist-path-rw` or the `whitelist:` key of your user config instead. If a worktree was moved, `git worktree repair` fixes the back-link.

### GPG commit signing:

To sign commits inside the sandbox without exposing your private keys, forward the host `gpg-agent`:

```bash
./ai-agent-sandbox.sh --gpg-agent
```

This works by forwarding the agent instead of the keys:

- The host's restricted `gpg-agent` extra socket (`gpgconf --list-dirs agent-extra-socket`, typically `/run/user/<uid>/gnupg/S.gpg-agent.extra`) is bind-mounted read-only into the sandbox at `/run/user/<uid>/gnupg/S.gpg-agent`, where `gpg` looks for its agent. The agent is launched on the host first if it is not running.
- Only **public keys** are imported into a temporary keyring that is mounted as `~/.gnupg` inside the sandbox and deleted on exit. Secret key material never enters the sandbox; the extra socket refuses key export and other privileged agent commands.
- The public key of `git config user.signingkey` is used if set (repository config in the working directory is honoured). Otherwise every key with secret material or a smartcard stub on the host is exported.
- The host's ownertrust for those keys is carried over so `git log --show-signature` verifies without trust warnings.
- Passphrase and touch prompts are handled by the host agent, so a hardware key (YubiKey, smartcard) keeps prompting on the host as usual.

`gpg` and `gpgconf` must be installed on the host and there must be at least one signing key. Only OpenPGP signing is forwarded; with `gpg.format = ssh` or `x509` a warning is printed.

### Profiles:

Profiles keep separate agent identities. Each profile has its own login, settings, memory and history, so you can use one Claude Code account for work, another provided by a customer, and a private one, without them ever seeing each other's data.

```bash
# Run with a named profile (created empty on first use)
./ai-agent-sandbox.sh --profile customer-x

# Same, via environment variable
AI_AGENT_SANDBOX_PROFILE=customer-x ./ai-agent-sandbox.sh

# List profiles
./ai-agent-sandbox.sh --list-profiles

# Force the host configuration even if the project pins a profile
./ai-agent-sandbox.sh --profile default
```

- The reserved profile `default` is the host configuration (`~/.claude`, `~/.claude.json`), which is what runs when no profile is given.
- A new profile starts with an empty configuration. Claude Code shows its onboarding and you log in with `/login` once; the credentials are stored in the profile, so the next run with that profile is already logged in.
- Profile data lives in `~/.local/share/ai-agent-sandbox/profiles/<name>/home/` (override the store with `AI_AGENT_SANDBOX_PROFILES_DIR`). The directory mirrors your home directory, so `profiles/<name>/home/.claude` is mounted at `~/.claude` inside the sandbox. OpenCode uses the same mechanism for `~/.config/opencode`, `~/.local/share/opencode`, `~/.local/state/opencode`, `~/.cache/opencode` and `~/.opencode.json`.
- The agent binary and its updates stay shared between profiles; only configuration, credentials and memory are per profile.
- Profile names may contain letters, digits, `.`, `_` and `-`.
- Skills are shared: everything in your host `~/.claude/skills` is visible in every profile, and a profile can add its own skills on top. Skills created inside a profile are stored in `profiles/<name>/home/.claude/skills` and are only visible there. A profile skill with the same name as a host skill takes precedence. Editing or deleting a shared skill inside a profile only affects that profile; the host directory is never modified. Changes made on the host are picked up the next time the sandbox starts. With `--agent opencode` the same applies to all three directories OpenCode loads skills from: `~/.config/opencode/skills`, `~/.claude/skills` and `~/.agents/skills`. A profile's `~/.claude/skills` is the same directory for both agents, so a skill added there is available to Claude Code and OpenCode in that profile. Use `--no-shared-skills` (or `shared_skills: false`) to give profiles only their own skills.
- To seed a new profile from your host settings without the login, copy what you want by hand, for example `cp -a ~/.claude/settings.json ~/.local/share/ai-agent-sandbox/profiles/<name>/home/.claude/`. Skills do not need to be copied; a copy made earlier takes precedence over the host version until you delete it from the profile.
- The profile store is hidden inside the sandbox even when a whitelist entry covers it (for example `~/.local/share`), so one profile can never read another profile's credentials.

Usually you do not pass `--profile` by hand: pin it per project in `.ai-agent-sandbox/config.yaml` (see [Configuration file](#configuration-file-configyaml)).

### Pass arguments to the selected agent:
```bash
./ai-agent-sandbox.sh -- --model claude-sonnet-4-5
```

Claude Code runs with `--dangerously-skip-permissions` by default: the sandbox is the safety net, so the agent does not have to ask. If you pass a permission flag yourself (`--permission-mode <mode>`, `--dangerously-skip-permissions` or `--allow-dangerously-skip-permissions`), the default is not added and your choice applies. Orchestrators such as T3 Code rely on this to keep their supervised modes supervised.

Native Claude Code updates are persistent across sandbox runs. The sandbox mounts Claude's version store read-write and uses a dedicated persistent launcher directory, rather than exposing every executable in `~/.local/bin` to writes.

```bash
./ai-agent-sandbox.sh -- update
```

With `--agent opencode` the arguments go to the `opencode` binary in the same way. The sandbox detects the installed OpenCode major version (`opencode --version` on the host) and adds its own defaults:

- **OpenCode 2** starts every command with `--standalone` and the interactive TUI and `run` with `--auto`. OpenCode 2 normally connects to one shared background server per user, which executes the agent's tools; from inside the sandbox that server would run on the host, so `--standalone` keeps the server inside the sandbox as a private child process. `--auto` replaces the OpenCode 1 permission environment variable. Flags you pass yourself (`--server`, `--standalone`, `--auto`) are left alone, and `--server` prints a warning because the tools then run wherever that server runs.
- **OpenCode 1** runs with `--agent build` and `OPENCODE_PERMISSION={"*":"allow"}` as before.

```bash
./ai-agent-sandbox.sh --agent opencode -- run -m deepseek/deepseek-chat "Explain this repository"
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

When Docker is enabled, the sandbox also mounts Docker CLI plugin directories from common host locations so `docker compose` works when the host Docker client has the Compose plugin installed. If `docker compose version` fails on the host, install Docker Compose on the host first.

### Using environment variables:
```bash
export AI_AGENT_SANDBOX_CONFIG=/path/to/config.yaml
export AI_AGENT_SANDBOX_CONFIG_LOCAL=/path/to/config.local.yaml
export AI_AGENT_SANDBOX_PROFILE=work
export AI_AGENT_SANDBOX_PROFILES_DIR=/path/to/profile-store
./ai-agent-sandbox.sh
```

### Using with T3 Code and other orchestrators

[T3 Code](https://github.com/pingdotgg/t3code) is a local control plane that drives the agent CLIs you already have installed: its server runs on your machine, owns git, worktrees and the integrated terminal, and starts Claude Code as a subprocess that talks to it over stdin/stdout. The sandbox fits in between: the T3 server keeps running on the host, and every agent it launches runs inside bubblewrap. No T3 changes are needed, only a wrapper that T3 uses as the Claude binary:

```sh
#!/bin/sh
# ~/.local/bin/claude-sandboxed  (chmod +x; do not give it a .js/.ts extension, T3 would run those with node)
exec /path/to/ai-agent-sandbox.sh --quiet --host-port 3773 -- "$@"
```

Then, in T3 Code:

1. **Settings → Providers → your Claude instance → Binary path**: the wrapper, e.g. `~/.local/bin/claude-sandboxed`. T3 passes its own flags (`--permission-mode`, `--add-dir`, `--resume`, ...) after `--`; the sandbox leaves them untouched.
   `--host-port 3773` keeps T3's MCP server (its tools for the agent) reachable from the isolated sandbox network; use the port of your T3 server if you changed it.
2. Whitelist T3's attachments directory, which T3 hands to Claude with `--add-dir` for images pasted into a thread: add `~/.t3/userdata/attachments` to the `whitelist:` of your user-level `config.yaml` (use your `T3CODE_HOME` if you changed it).
3. To run T3 threads under a sandbox [profile](#profiles), add the environment variable `AI_AGENT_SANDBOX_PROFILE=<name>` to the provider instance (**Settings → Providers → instance → Environment variables**) and set the instance's **CLAUDE_CONFIG_DIR path** to `~/.local/share/ai-agent-sandbox/profiles/<name>/home/.claude`, so that T3's host-side readers (thread history, usage limits) look at the same directory the sandbox mounts as `~/.claude`. The sandbox ignores `CLAUDE_CONFIG_DIR` itself and uses the profile.

Good to know:

- T3 creates worktrees under `~/.t3/worktrees/<repo>/<branch>`; the sandbox follows the worktree's `.git` link (see [Git worktrees](#git-worktrees)), so git keeps working for the agent.
- T3 discards the agent's stderr, where the sandbox logs. While setting things up, append `2>>"$HOME/.local/state/ai-agent-sandbox/t3.log"` to the `exec` line and drop `--quiet` to see what the sandbox does. T3 also runs its periodic health probe and `--version` check through the wrapper (no API calls, the working directory may be `~/.t3/userdata`).
- The project configuration in `.ai-agent-sandbox/` of the worktree applies as usual.
- T3's own integrated terminal, git operations and project setup scripts run on the host, outside the sandbox, by design: they are driven by you, not by the model.
- A stop from T3 (or any `SIGTERM` to the wrapper) terminates the sandbox immediately.
- OpenCode 1 works the same way (`--agent opencode`, T3 runs `opencode serve` per thread in the project directory). OpenCode 2 runs one server for all directories, which a per-directory sandbox cannot confine. Codex is not supported by the sandbox yet.

## Configuration

### Multiple Configuration Files

All configuration lives in YAML config files, which are processed in order:

1. **User-level files** (always included if they exist):
   - `~/.config/ai-agent-sandbox/config.yaml`
   - `~/.config/ai-agent-sandbox/config.local.yaml` (loaded after `config.yaml`, overrides its values, e.g. machine-specific settings)
   - If neither exists (and there are no [legacy files](#legacy-configuration-files-deprecated)), `config.yaml` is auto-generated with a default whitelist and blacklist

2. **Project-level files** (automatically included if they exist):
   - `.ai-agent-sandbox/config.yaml` (in working directory, commit to version control)
   - `.ai-agent-sandbox/config.local.yaml` (in working directory, personal overrides, add to `.gitignore`)
   - **Never auto-generated** - create manually if needed

3. **Command-line options**

The locations of the user-level files can be changed with `AI_AGENT_SANDBOX_CONFIG` and `AI_AGENT_SANDBOX_CONFIG_LOCAL`.

### Legacy configuration files (deprecated)

Before `config.yaml` existed, the configuration was split into `whitelist.txt`, `blacklist.txt`, `.env` and `.env.local` in `~/.config/ai-agent-sandbox/` and `.ai-agent-sandbox/`. These files are **deprecated** and support for them will be dropped in a future release:

- At a level (user or project) that has a `config.yaml` or `config.local.yaml`, the legacy files of that level are **ignored** and a warning lists them.
- At a level without a YAML config file, the legacy files are still used, with a warning that their support will be dropped.
- The `--whitelist FILE`, `--blacklist FILE` and `--env-path FILE` options and the `whitelist_files`, `blacklist_files` and `env_files` config keys have been **removed**; using them is an error.
- The environment variables `AI_AGENT_SANDBOX_WHITELIST`, `AI_AGENT_SANDBOX_BLACKLIST`, `AI_AGENT_SANDBOX_ENV` and `AI_AGENT_SANDBOX_ENV_LOCAL` still set the locations of the user-level legacy files.

**Automatic migration.** The migration moves `whitelist.txt` into the `whitelist:` list, `blacklist.txt` into the `blacklist:` list and `.env` into the `env:` mapping of the `config.yaml` at the same level, and `.env.local` into the `env:` mapping of `config.local.yaml`. Entries already present in the YAML file are kept; nothing is written unless every file can be merged. The old files are renamed to `*.migrated`; delete them once you have checked the result.

- **User-level files:** when the sandbox starts in a terminal and finds legacy files in `~/.config/ai-agent-sandbox/`, it explains the situation and asks whether to migrate them. After migrating it restarts with the new configuration. If you decline, or the start is not interactive, only the warning is printed and you are asked again next time.
- **Project-level files** are never migrated automatically: they are usually tracked in git, and every team member needs a sandbox version that reads `config.yaml` before the old files disappear. Migrate them explicitly, then review and commit:
  ```bash
  ./ai-agent-sandbox.sh --migrate-project-conf
  ```
  If `.env.local` was migrated, make sure `.ai-agent-sandbox/config.local.yaml` is in `.gitignore` (the command warns if it is not).

To migrate by hand, move the entries as described above; entry syntax is unchanged. Quote entries that start with `*` or `!` or contain `: `, e.g. `- "**/.env"`. A `.env` line `KEY=VALUE` becomes `KEY: VALUE`.

### Configuration file (config.yaml)

Everything that can be passed on the command line can also be put into a YAML config file. A typical project file pins the profile and a few paths:

```yaml
# .ai-agent-sandbox/config.yaml
profile: customer-x
docker: true
whitelist:
  - ~/.m2/repository:rw
blacklist:
  - secrets/
env:
  NODE_OPTIONS: "--max-old-space-size=4096"
agent_args: [--model, claude-sonnet-4-5]
```

See [`config-example.yaml`](config-example.yaml) for a commented example of every key.

| Key | Type | Equivalent flag |
|---|---|---|
| `profile` | string | `--profile NAME` (`default` = host configuration) |
| `agent` | string | `--agent claudecode\|opencode` |
| `network` | string | `--network isolated\|host\|none` (default: `isolated`, see [Network isolation](#network-isolation)) |
| `host_ports` | list | `--host-port PORT` (host loopback TCP ports or ranges `a-b` reachable at localhost inside) |
| `allow_hosts` | list | `--allow-host ADDR` (IPs, CIDR ranges or hostnames exempt from the private-network block) |
| `docker` | bool | `--enable-docker` / `--no-docker` |
| `docker_image` | string | `--docker-image IMAGE` |
| `venv` | bool | `--venv` / `--no-venv` |
| `gitconfig` | bool | `--gitconfig` / `--no-gitconfig` |
| `shared_skills` | bool | `--shared-skills` / `--no-shared-skills` (default: shared) |
| `gpg_agent` | bool | `--gpg-agent` / `--no-gpg-agent` |
| `quiet` | bool | `--quiet` / `--verbose` |
| `whitelist` | list | see [Whitelist Format](#whitelist-format) (relative paths, globs, `**`, `:rw`, `!`) |
| `blacklist` | list | `--blacklist-path PATTERN` |
| `env` | mapping | `--env KEY=VALUE`; values follow the [environment file rules](#environment-variables) |
| `agent_args` | list | arguments always passed to the agent, before anything given after `--` |
| `protect_project_config` | bool | `--no-protect-project-config`; only honoured in the user-level file |

**Precedence:** `~/.config/ai-agent-sandbox/config.yaml` < `~/.config/ai-agent-sandbox/config.local.yaml` < `.ai-agent-sandbox/config.yaml` < `.ai-agent-sandbox/config.local.yaml` < `AI_AGENT_SANDBOX_PROFILE` < command-line flags. Scalars from a later source override earlier ones; lists are merged. Relative paths are resolved against the working directory.

**Supported YAML subset.** The file is parsed by the script itself, without `yq`, so only a flat subset of YAML is understood:
- `key: value` scalars; quoted (`"..."` or `'...'`) or unquoted. Booleans accept `true/false`, `yes/no`, `on/off`; anything else is an error.
- Block lists (`key:` followed by `- item` lines) and inline lists (`key: [a, b]`, items may not contain commas). A single scalar is accepted for a list key.
- `env:` followed by indented `KEY: value` lines, or inline `env: {KEY: value}`.
- Comments (`#` at the start of a line or after whitespace), `---` document markers, tabs and CRLF line endings are tolerated. `~` or `null` unsets a scalar.
- Nested mappings (other than `env`), anchors, multi-line strings and unknown keys are reported as warnings and ignored.

**Project config protection.** Because `.ai-agent-sandbox/` lives inside the read-write working directory, an agent could otherwise edit its own sandbox rules (switch to the host profile, whitelist `~/.ssh`, change `ANTHROPIC_BASE_URL`) to take effect on the next run. The directory is therefore mounted read-only inside the sandbox by default. Disable it with `--no-protect-project-config` or `protect_project_config: false` in the user-level config; the setting is deliberately ignored in project files. If the directory does not exist yet, the agent can still create it, so review a new `.ai-agent-sandbox/` before your next run. The resolved profile and its source are printed in the startup summary.

All files are merged together, allowing you to:
- Maintain a base configuration in the user-level file
- Add project-specific rules in `.ai-agent-sandbox/config.yaml` (can be committed to version control)
- Override with command-line flags
- Share configurations across teams and projects

### Environment Variables

The `env:` mapping sets variables inside the sandbox:

```yaml
env:
  API_TOKEN: secret
  FEATURE_FLAG: "true"
  QUOTED_VALUE: "value with spaces"
  # Values may reference other variables and use ~ for $HOME
  PATH: "~/.local/share/mise/installs/node/25/bin:$PATH"
  BASE: ~/apps
  TOOL_BIN: "$BASE/bin"
  LITERAL: 'no $expansion here'
```

**Important:**
- Values are exposed inside the sandbox via `bubblewrap --setenv`.
- Later entries override earlier entries when the same key appears multiple times.
- Variable names must match shell environment naming rules, such as `API_TOKEN` or `_PRIVATE`.
- Logs show variable names only, not values.

**Variable expansion:**
- `$VAR` and `${VAR}` references are expanded in unquoted and double-quoted values.
- References resolve against the sandbox environment first (values set by earlier env entries or by the script itself, such as `PATH` and `HOME`), then fall back to the host environment; undefined variables expand to empty.
- A leading `~` (and `~` after `:` in PATH-style lists) expands to `$HOME`.
- Single-quoted values are taken literally with no expansion.
- Use `\$` for a literal dollar sign in expanded values.

### Whitelist Format

The `whitelist:` list contains **paths or glob patterns** that the agent can read:

```yaml
whitelist:
  # System binaries (read-only by default)
  - /usr/bin
  - /usr/lib
  # Java tools (for Java developers) - using glob patterns
  - /usr/lib/jvm
  - /etc/java*
  - /etc/maven
  # Maven cache with read-write access
  - ~/.m2/repository:rw
  # Custom paths with read-write for specific directory
  - /opt/company/shared-cache:rw
  # Glob pattern with read-write
  - /opt/build-*:rw
  # Re-allow a blacklisted file
  - "!secrets/dev.key"
```

**Important:**
- Paths are absolute (start with `/`, `~` or `$HOME`) or relative to the working directory
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
- Environment variables like `$HOME` are expanded
- Entries from all config files are merged

### Blacklist Format

The `blacklist:` list contains **relative paths** from the working directory that the agent cannot access:

```yaml
blacklist:
  # Environment files
  - "**/.env"
  - "**/.env.*"
  # SSH keys
  - "**/*.pem"
  - "**/*.key"
  - "**/id_rsa"
  - "**/id_ed25519"
  # Cloud credentials
  - "**/.aws"
  - "**/.gcp"
```

**Important:**
- Paths are relative to the working directory
- **Pattern support**:
  - Simple glob: `*`, `?` (e.g., `*.env` matches `.env.local`, `.env.prod`)
  - **Ant-style recursive**: `**` for recursive matching (e.g., `**/wallet.dat` matches `wallet.dat` anywhere in the working directory tree)
- Trailing `/` is accepted and normalized (for example, `secret-data/` behaves like `secret-data`)
- Patterns from all config files are merged

### Symlink behavior

- Matching is done on paths inside the working directory, so symlink names can be matched by whitelist/blacklist patterns.
- **Whitelist**: symlink paths are allowed when they resolve to an existing target at sandbox startup.
- **Blacklist**: matched symlinks are resolved to their canonical target path.
- If the resolved blacklist target is inside the working directory, the target is hidden.
- If the resolved blacklist target is outside the working directory (or cannot be resolved), the entry is skipped.

**Examples of ant-style patterns:**
```yaml
blacklist:
  # Block wallet.dat anywhere in the project
  - "**/wallet.dat"
  # Block all .env files recursively
  - "**/.env"
  # Block all private key files anywhere
  - "**/*.pem"
  - "**/*.key"
  # Block test secrets in any test directory
  - "**/test/**/secrets.json"
```

## Security Considerations

### What This Script Protects Against

1. ✅ **Filesystem access outside working directory** - Only whitelisted system paths are readable
2. ✅ **Sensitive files in working directory** - Blacklisted patterns are hidden
3. ✅ **SSH agent access** - SSH_AUTH_SOCK is removed from environment
4. ✅ **Home directory access** - Only minimal agent-specific config is exposed
5. ✅ **Credential separation** - With profiles, a project only sees the login, settings and memory of its own profile; the profile store itself is never visible inside the sandbox
6. ✅ **Self-modifying sandbox rules** - `.ai-agent-sandbox/` is mounted read-only so the agent cannot change the profile, whitelist or environment it runs with next time
7. ✅ **OpenCode 2 background server** - OpenCode 2 is started with `--standalone`, so the server that executes its tools runs inside the sandbox instead of the shared per-user service on the host
8. ✅ **Host services and LAN** - In the default `isolated` network mode the host's loopback and private networks are unreachable, so a prompt-injected agent cannot probe local databases, dashboards, routers or other machines; only the ports and hosts you list are exposed

### Limitations and Considerations

1. ⚠️ **Internet access** - The agent reaches the internet (and therefore its LLM provider) in both `isolated` and `host` mode. `--network host` also gives it the host loopback and the LAN; `--network none` cuts everything but is only useful for offline runs.

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


## Troubleshooting

### "bubblewrap is not installed"
Install bubblewrap using your package manager (see Requirements section).

### "agent is not installed"
Install the selected agent. Claude Code and OpenCode are currently supported.

### OpenCode reports "Unrecognized flag" for an argument
OpenCode 2 changed its command line: `--agent` and `--model` only exist on `run` and `mini`, `--port` and `--attach` are gone. The `Agent Command:` line in the startup summary shows the exact command the sandbox runs, including the defaults it adds for the detected major version.

### The agent can't access necessary system libraries
Add the required paths to the `whitelist:` list in your `config.yaml`. Common additions:
- `/usr/lib/x86_64-linux-gnu` (Debian/Ubuntu)
- `/usr/lib64` (RedHat/Fedora)
- `/opt/custom-tools`

### The sandbox uses the wrong Claude account
Check the `Profile:` line in the startup summary; it shows the profile and where it came from (`.ai-agent-sandbox/config.yaml`, `config.local.yaml`, `AI_AGENT_SANDBOX_PROFILE` or `--profile`). Use `--profile default` to force the host configuration, or `--list-profiles` to see which profiles are logged in.

### The agent needs to access a specific sensitive file
If you genuinely need the agent to access a file that's blacklisted:
1. Add an override entry to the whitelist (prefix with `!`), or
2. Remove it from the blacklist, or
3. Create a copy outside the blacklisted pattern

## Examples

### Using multiple configuration files

You can maintain layered configurations at different levels:

```yaml
# Layer 1: User-level (~/.config/ai-agent-sandbox/config.yaml)
whitelist:
  - /usr/bin
  - /usr/lib
  - /usr/share
```

```yaml
# Layer 2: Project-level (.ai-agent-sandbox/config.yaml in your project, committed to git)
whitelist:
  - /opt/project-tools
  - /usr/lib/project-dependencies
blacklist:
  - .env.local
  - secrets/
  - "*.key"
```

```yaml
# Layer 3: Personal overrides (.ai-agent-sandbox/config.local.yaml, in .gitignore)
profile: customer-x
env:
  API_TOKEN: secret
```

The project files are used automatically when running in that directory. This approach allows you to:
- Keep common system paths in the user-level file
- Add project-specific rules in `.ai-agent-sandbox/` (version controlled)
- Share configurations across team members
- Override with command-line flags when needed

### Java developer setup:
```yaml
whitelist:
  # Java tools
  - /etc/java*
  - /etc/maven
  - ~/.m2/repository:rw  # Maven cache (read-write so the agent can download dependencies)
blacklist:
  - .env
  - application-secrets.yml
  - keystore.jks
```

### DevOps/Ansible/Docker setup:
```yaml
whitelist:
  # DevOps tools
  - /usr/libexec/docker
docker: true
blacklist:
  - .env
  - "*vault*.yml"
  - ansible-vault.key
  - inventory/production
  - .ssh
  - "*.pem"
```

## Contributing

Suggestions for improvements:
1. More sophisticated overlay filesystem handling
2. Integration with security audit tools
3. Preset profiles for common development stacks
4. Domain-level egress filtering (currently deliberately out of scope)

## Security Disclosure

If you find security issues with this sandboxing approach, please consider responsible disclosure practices.
