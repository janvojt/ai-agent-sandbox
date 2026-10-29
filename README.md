# AI Agent Sandbox Script

A secure bubblewrap-based sandboxing solution for running AI coding agents with strict filesystem isolation.

## Features

- ✅ **Whitelist-based filesystem access** - Only explicitly allowed paths are readable
- ✅ **Blacklist protection** - Block sensitive files within working directory
- ✅ **Network isolation** - Internet access through user-mode networking, while the host's loopback services and private networks stay hidden (`--network host` for full access)
- ✅ **Syscall filter** - A seccomp deny list keeps rarely needed, exploit-prone kernel interfaces (keyrings, BPF, io_uring, terminal injection, new user namespaces, mounts) away from the agent; `--seccomp nested` allows namespaces again for nested sandboxes
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
- **python3** (3.8 or newer, only for `--enable-docker`: runs the Docker API filter on the host)
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

Run it from the project directory: the current directory becomes the agent's read-write working directory. The sandbox refuses to start in your home directory or one of its parents (such as `/`), because the agent would get read-write access to everything in it; pass `--allow-home-workdir` if you really want that. The one exception is OpenCode's ACP agent (`--agent opencode -- acp`) started in the home directory itself: it runs without any working directory mounted (an orchestrator's health check, see [Using with T3 Code](#using-with-t3-code-and-other-orchestrators)).

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
- Unix sockets (Docker proxy, GPG agent) are unaffected;
- `ping` works for internet hosts (ICMP echo is relayed by pasta); the sandbox has no `CAP_NET_RAW`, so `traceroute`, raw sockets and other ICMP types do not.

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

Requirements: `pasta` (package `passt`), `nsenter` and `unshare --map-user` (util-linux 2.38 or newer, e.g. Ubuntu 24.04) and `ip` (iproute2) on the host. Without them the default mode falls back to the host network with a warning; an explicitly requested `isolated` mode fails instead.

Limits: LAN machines with public IP addresses on subnets the host is not directly attached to are indistinguishable from the internet. Blocking the internet itself is pointless, the agent talks to its LLM provider anyway. With `--enable-docker`, containers' published ports live on the host loopback, so list them in `host_ports` (or use `--network host`); the `172.17.x` bridge addresses are blocked.

### Syscall filter:

The agent shares the host kernel, so every kernel bug it can reach is a way out. The sandbox therefore installs a seccomp filter (assembled by the script itself, no libseccomp needed) with a deny list of syscalls that coding agents do not need and that keep showing up in kernel exploits:

| Level | Refused |
|---|---|
| `nested` | kernel keyrings (`keyctl`, `add_key`, `request_key`), `bpf`, `userfaultfd`, `perf_event_open`, module and kexec loading, NUMA page migration, `syslog`, `acct`, `quotactl`, `open_by_handle_at`, `modify_ldt`/`vm86`, `ioctl(TIOCSTI/TIOCLINUX)` (typing commands into the terminal the agent was started from) and exotic `personality` flags; `io_uring` reports "not implemented" so runtimes fall back to their normal I/O |
| `strict` (used unless configured otherwise) | everything from `nested`, plus new user namespaces (`unshare`, `setns`, `clone` with `CLONE_NEWUSER`; `clone3` reports "not implemented", glibc then uses `clone`) and every mount syscall. Closes the netfilter/nf_tables class of exploits that need namespace root, but nested sandboxes stop working: bwrap, rootless Podman, Flatpak, Claude Code's own sandbox, Chromium's sandbox (Puppeteer needs `--no-sandbox`; Playwright already passes it) and this project's integration tests. Docker through `--enable-docker` is not affected, the daemon runs on the host |
| `off` | nothing |

```bash
# Allow nested sandboxes (rootless Podman, bwrap) for this run
./ai-agent-sandbox.sh --seccomp nested
AI_AGENT_SANDBOX_SECCOMP=off ./ai-agent-sandbox.sh
```

The config key is `seccomp`. A project file may only **tighten** the level: with the default `strict`, `seccomp: nested` or `seccomp: off` in a repository is ignored with a warning. To use nested sandboxes in a project, set `seccomp: nested` in your user-level `config.yaml`/`config.local.yaml` or pass the flag (for example in an orchestrator wrapper); the environment variable works as well. 32-bit x86 programs are filtered with their own syscall numbers; x32 and 32-bit ARM programs cannot run under the filter. Supported architectures are x86_64 and aarch64; elsewhere the default switches the filter off with a warning, an explicit level fails. `perf`, `bpftrace` and other tools that need the refused syscalls work with `--seccomp off`.

**Terminal input injection.** A process attached to the terminal you started the sandbox from can push keystrokes into it (`ioctl(TIOCSTI)`), which your shell would execute after the agent exits. The syscall filter refuses that ioctl, and kernels since 6.2 refuse it to unprivileged processes when `dev.tty.legacy_tiocsti` is 0. When neither applies (`--seccomp off` on such a kernel), and whenever no terminal is attached at all (orchestrators), the sandbox is started in a new session (`bwrap --new-session`) so it has no controlling terminal. In a terminal that has a price, window resizes do not reach the agent, so it is not done when the filter already covers it. `--new-session` / `--no-new-session` force the choice; the summary line `Terminal Session:` shows it.

It is a deny list, not an allow list: bugs in ordinary syscalls (file systems, networking, memory management) are still reachable. Only a VM separates the agent from the host kernel.

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

Usually you do not pass `--profile` by hand: pin it per project in `.ai-agent-sandbox/config.yaml`, or in the git-ignored `.ai-agent-sandbox/config.local.yaml` if the choice is personal (see [Configuration file](#configuration-file-configyaml)).

A profile pinned in a project file is a requirement, not just a default: when `AI_AGENT_SANDBOX_PROFILE` names a *different* profile, the sandbox refuses to start instead of silently using it (the environment variable still wins over the project otherwise, so a repository cannot switch your credentials, only refuse the wrong ones). This catches a T3 thread started with the provider instance of the wrong account. With `--strict-profile`, a missing `AI_AGENT_SANDBOX_PROFILE` counts as `default`. Use it in an orchestrator's wrapper: a T3 provider instance without the variable uses your host configuration, so a project pinned to `work` then also refuses that instance. Without the flag (e.g. in a terminal), a missing variable just means the project's profile applies. `--profile` on the command line is a deliberate choice and overrides the project without an error.

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

Docker access goes through two layers started for each run. The sandbox only sees `.docker-proxy/docker.sock` in the working directory (mode 0600). The script serves that socket from a **Docker API filter** on the host, which forwards to a socket proxy container ([wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy)) holding the real Docker socket. Access to the Docker daemon is root on the host, so the filter refuses everything that would give a container access to the host:

- privileged containers, host PID/IPC/network/UTS/user/cgroup namespaces, added capabilities other than those acting only inside the container (`NET_ADMIN`, `SYS_PTRACE`, `IPC_LOCK`, `SYS_NICE`, …), devices and GPU requests, `seccomp`/`apparmor`/`systempaths=unconfined` and `label=disable`, other runtimes and cgroup parents;
- privileged `docker exec`;
- volumes that mount host block devices or network shares (only `tmpfs` and bind options, whose paths the proxy checks), volume drivers and network drivers other than `local`/`bridge` (no `macvlan`/`ipvlan` on your LAN);
- plugins and swarm, host-network builds, and API endpoints it does not know.

Containers, volumes and networks created through the sandbox get the label `ai-agent-sandbox.owner=<working directory>`. Every operation on an existing object (inspect, exec, attach, copy, logs, stop, remove, joining its network or namespaces, mounting its volume) requires that label, and lists, prunes and events only show labelled objects. So the agent cannot read the environment of your other containers, exec into them, delete your databases' volumes or reach the socket proxy itself. A named volume that does not exist yet is created with the label. `MKNOD` is dropped from every container, so no device nodes appear in mounted directories.

Builds use the daemon's built-in BuildKit (`/session` and `/grpc`). A buildx builder with the `docker-container` driver runs BuildKit in a privileged container and is therefore refused: use the default `docker` driver.

Limits:
- Containers run on Docker's bridge networks, outside the sandbox's network namespace: they can reach your LAN and host services listening on the Docker bridge, so `--network isolated` does not apply to them (nor to builds).
- With a rootful Docker daemon, root in a container is root on the host. A container can leave root-owned setuid binaries in a mounted directory, which run as root when you execute them on the host (for example through a project script). Rootless Docker or `userns-remap` removes that; the startup log warns when neither is in use.

The proxy only allows bind mounts from paths already accessible inside the sandbox (working directory and any read-write mounts). Paths containing sandbox or git configuration (see *Project config protection* and *Git config protection*) are refused, because a container would see the host directory without the sandbox's read-only mounts: with protection on, the working directory itself cannot be mounted (`-v "$PWD:/app"`), mount its subdirectories instead (`-v "$PWD/src:/app/src"`). Entries created in such a directory after the sandbox started cannot be mounted either.

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

[T3 Code](https://github.com/pingdotgg/t3code) is a local control plane that drives the agent CLIs you already have installed: its server runs on your machine, owns git, worktrees and the integrated terminal, and starts Claude Code as a subprocess that talks to it over stdin/stdout. The sandbox fits in between: the T3 server keeps running on the host, and every agent it launches runs inside bubblewrap. No T3 changes are needed, only a wrapper that T3 uses as the Claude binary (`/home/you` stands for your home directory):

```sh
#!/bin/sh
# /home/you/.local/bin/claude-sandboxed  (chmod +x; do not give it a .js/.ts extension, T3 would run those with node)
exec /home/you/ai-agent-sandbox/ai-agent-sandbox.sh --quiet --host-port 3773 --strict-profile -- "$@"
```

Then, in T3 Code (enter every path in T3's settings as an absolute path: T3 expands `~` in some fields, such as the Claude binary path, but not in others, such as the OpenCode binary path, where `~/...` fails with "not installed or not on PATH"):

1. **Settings → Providers → your Claude instance → Binary path**: the wrapper, e.g. `/home/you/.local/bin/claude-sandboxed`. T3 passes its own flags (`--permission-mode`, `--add-dir`, `--resume`, ...) after `--`; the sandbox leaves them untouched.
   `--host-port 3773` keeps T3's MCP server (its tools for the agent) reachable from the isolated sandbox network; use the port of your T3 server if you changed it.
2. Whitelist T3's attachments directory, which T3 hands to Claude with `--add-dir` for images pasted into a thread: add `/home/you/.t3/userdata/attachments` to the `whitelist:` of your user-level `config.yaml` (use your `T3CODE_HOME` if you changed it).
3. To run T3 threads under a sandbox [profile](#profiles), add the environment variable `AI_AGENT_SANDBOX_PROFILE=<name>` to the provider instance (**Settings → Providers → instance → Environment variables**) and set the instance's **CLAUDE_CONFIG_DIR path** to `/home/you/.local/share/ai-agent-sandbox/profiles/<name>/home/.claude`, so that T3's host-side readers (thread history, usage limits) look at the same directory the sandbox mounts as `~/.claude`. The sandbox ignores `CLAUDE_CONFIG_DIR` itself and uses the profile.
4. With one provider instance per profile (say, work and private subscriptions), make each project use the right one:
   - In T3, set the project's default model to a model of the matching instance, so new threads start with it.
   - In the sandbox, pin the profile in the project's `.ai-agent-sandbox/config.local.yaml` (`profile: work`, or `profile: default` for projects that use the instance without `AI_AGENT_SANDBOX_PROFILE`, i.e. your host configuration). A thread started with the other instance then fails on its first message ("profile mismatch") instead of running on the wrong subscription; T3 only shows that the provider exited, the reason is in the log file mentioned below. The file is git-ignored and therefore not copied into T3's worktrees, so the sandbox reads it from the main checkout when the worktree has none (see [Git worktrees](#git-worktrees)).

Good to know:

- T3 creates worktrees under `/home/you/.t3/worktrees/<repo>/<branch>`; the sandbox follows the worktree's `.git` link (see [Git worktrees](#git-worktrees)), so git keeps working for the agent.
- T3 discards the agent's stderr, where the sandbox logs. While setting things up, append `2>>"$HOME/.local/state/ai-agent-sandbox/t3.log"` to the `exec` line and drop `--quiet` to see what the sandbox does. T3 also runs its periodic health probe and `--version` check through the wrapper (no API calls, the working directory may be `/home/you/.t3/userdata` or T3's own working directory). A bare `--version` (or `-v`) is answered by the host binary without starting a sandbox, so the check stays fast in any directory; `--dry-run` still runs it inside.
- The project configuration in `.ai-agent-sandbox/` of the worktree applies as usual, plus the main checkout's `config.local.yaml` if the worktree has none.
- T3's own integrated terminal, git operations and project setup scripts run on the host, outside the sandbox, by design: they are driven by you, not by the model.
- A stop from T3 (or any `SIGTERM` to the wrapper) terminates the sandbox immediately.
- Codex is not supported by the sandbox yet.

#### OpenCode in T3 Code (through ACP)

T3's own OpenCode provider cannot be sandboxed: it starts a single shared `opencode serve` in T3's working directory, usually your home directory, and sends every thread to it as a request for that thread's project directory. The sandbox refuses to start there (see [Basic usage](#basic-usage)), so T3 shows that provider as failing. Use T3's **ACP** provider instead: with a local command it starts one process per thread in the thread's directory, like Claude, and `opencode acp` (OpenCode 2) speaks the Agent Client Protocol on stdin/stdout with its own private server. Every thread then gets its own sandbox of its own project. The wrapper:

```sh
#!/bin/sh
# /home/you/.local/bin/opencode-acp-sandboxed  (chmod +x; needs jq on the host)

# Hand T3's MCP server (its tools for the agent) to OpenCode
if [ -n "${T3_ACP_MCP_ENDPOINT:-}" ] &&
   [ -n "${T3_ACP_MCP_AUTHORIZATION:-}" ]; then
    OPENCODE_CONFIG_CONTENT=$(jq -nc \
        --arg url "$T3_ACP_MCP_ENDPOINT" \
        --arg auth "$T3_ACP_MCP_AUTHORIZATION" \
        '{mcp: {servers: {t3: {type: "remote", url: $url, enabled: true, oauth: false,
                     headers: {Authorization: $auth}}}}}')
    export OPENCODE_CONFIG_CONTENT
fi

exec /home/you/ai-agent-sandbox/ai-agent-sandbox.sh --agent opencode --quiet --host-port 3773 -- acp "$@"
```

T3 passes the address and token of its MCP server to an ACP agent in `T3_ACP_MCP_ENDPOINT` and `T3_ACP_MCP_AUTHORIZATION`, but OpenCode does not read them, and the sandbox does not pass them through (see [Environment Variables](#environment-variables)). The wrapper therefore builds the OpenCode configuration on the host, with the values filled in, and hands it over in `OPENCODE_CONFIG_CONTENT`, which does reach the sandbox. Do not use OpenCode's `{env:T3_ACP_MCP_...}` substitution instead: it is resolved inside the sandbox, where the variables are empty. The token only lives in the environment of the launched process; nothing is written to your OpenCode configuration. `--host-port 3773` makes T3's port reachable from the isolated sandbox network (use the port of your T3 server if you changed it). OpenCode 2 expects servers under `mcp.servers`. To check the wrapper: `T3_ACP_MCP_ENDPOINT=http://127.0.0.1:3773/mcp T3_ACP_MCP_AUTHORIZATION="Bearer test" /home/you/.local/bin/opencode-acp-sandboxed debug config` should show a `t3` entry under `mcp.servers`.

Keep `acp` the first argument after `--`: the sandbox only accepts T3's health check in your home directory (see below) for exactly that form, anything before it (such as `--print-logs`) makes it refuse with "the working directory … is your home directory". Put extra OpenCode flags after `acp`.

Then, in T3 Code:

1. **Settings → Providers → add an ACP provider instance → ACP source: Local command**, and set **Executable override** to the wrapper, e.g. `/home/you/.local/bin/opencode-acp-sandboxed` (absolute path). Disable the built-in OpenCode provider.
2. Profiles work per project with a single instance: leave `AI_AGENT_SANDBOX_PROFILE` out of the instance and pin the profile in each project's `.ai-agent-sandbox/config.local.yaml` (`profile: work`); projects without a pin use your host configuration. T3 reads ACP threads through the protocol, not from the profile's files, so unlike Claude no instance per profile is needed. Prefer the git-ignored `config.local.yaml` (read from the main checkout in worktrees, see [Git worktrees](#git-worktrees)) over the committed `config.yaml`, so a repository cannot choose your credentials.
3. Log in once per profile in a terminal, from any project directory: `./ai-agent-sandbox.sh --agent opencode --profile work -- auth login` (`--profile default` for your host configuration).

Good to know:

- T3 runs its health check (initialize, sign-in state, models) by starting the wrapper in its own working directory, usually your home directory. There is no project there, so the sandbox mounts no working directory at all: the agent only gets its private home and the profile's OpenCode configuration (the summary shows `not mounted: ACP agent without a project`). Relative whitelist entries are skipped and Docker is off in that case. That check runs under the profile without a pin (your host configuration by default), so T3's sign-in state and model list are those of that profile.
- Every new thread starts a sandbox and a fresh OpenCode server, which takes a few seconds. T3 resumes a thread by asking the new process to load its session, which OpenCode keeps in the profile's database.
- After changing the wrapper, disable and re-enable (or reconnect) the ACP provider in T3 and start a new thread; running threads keep the process they were started with.
- T3's generic ACP integration does not have every feature of its native OpenCode provider (for example OpenCode Go usage limits).
- Logging, worktrees, the project configuration and stopping behave as for Claude above.

## Configuration

### Multiple Configuration Files

All configuration lives in YAML config files, which are processed in order:

1. **User-level files** (always included if they exist):
   - `~/.config/ai-agent-sandbox/config.yaml`
   - `~/.config/ai-agent-sandbox/config.local.yaml` (loaded after `config.yaml`, overrides its values, e.g. machine-specific settings)
   - If neither exists (and there are no [legacy files](#legacy-configuration-files-deprecated)), `config.yaml` is auto-generated with a default whitelist and blacklist

2. **Project-level files** (automatically included if they exist):
   - `.ai-agent-sandbox/config.yaml` (in working directory, commit to version control)
   - `.ai-agent-sandbox/config.local.yaml` (in working directory, personal overrides, add to `.gitignore`). In a [git worktree](#git-worktrees) without its own `config.local.yaml`, the main checkout's file is used, because git does not copy ignored files into new worktrees
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
| `seccomp` | string | `--seccomp strict\|nested\|off` (default: `strict`, project files may only tighten it, see [Syscall filter](#syscall-filter)) |
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
| `protect_git_config` | bool | `--protect-git-config` / `--no-protect-git-config`; only honoured in the user-level file |

**Precedence:** `~/.config/ai-agent-sandbox/config.yaml` < `~/.config/ai-agent-sandbox/config.local.yaml` < `.ai-agent-sandbox/config.yaml` < `.ai-agent-sandbox/config.local.yaml` < `AI_AGENT_SANDBOX_PROFILE` < command-line flags. Scalars from a later source override earlier ones; lists are merged. Relative paths are resolved against the working directory. Exception: a `profile` from a project file is not overridden by a different `AI_AGENT_SANDBOX_PROFILE`, that is an error (see [Profiles](#profiles)).

**Supported YAML subset.** The file is parsed by the script itself, without `yq`, so only a flat subset of YAML is understood:
- `key: value` scalars; quoted (`"..."` or `'...'`) or unquoted. Booleans accept `true/false`, `yes/no`, `on/off`; anything else is an error.
- Block lists (`key:` followed by `- item` lines) and inline lists (`key: [a, b]`, items may not contain commas). A single scalar is accepted for a list key.
- `env:` followed by indented `KEY: value` lines, or inline `env: {KEY: value}`.
- Comments (`#` at the start of a line or after whitespace), `---` document markers, tabs and CRLF line endings are tolerated. `~` or `null` unsets a scalar.
- Nested mappings (other than `env`), anchors, multi-line strings and unknown keys are reported as warnings and ignored.

**Project config protection.** Because `.ai-agent-sandbox/` lives inside the read-write working directory, an agent could otherwise edit its own sandbox rules (switch to the host profile, whitelist `~/.ssh`, change `ANTHROPIC_BASE_URL`) to take effect on the next run. The same applies to other projects reachable through a read-write whitelist entry and to the user-level configuration. By default every `.ai-agent-sandbox/` inside a read-write mount (at any depth) and the user-level configuration directory (`~/.config/ai-agent-sandbox`, or the files and their symlink targets when `AI_AGENT_SANDBOX_CONFIG*` point elsewhere) are therefore mounted read-only, also when a whitelisted parent directory would otherwise make them writable. So the agent cannot create one either, an empty `.ai-agent-sandbox/` is created on the host in the working directory and in read-write whitelisted git repository roots that have none (git does not track empty directories). Deeper directories without one stay a gap: review a new `.ai-agent-sandbox/` that you did not create before running a sandbox there. Disable all of this with `--no-protect-project-config` or `protect_project_config: false` in the user-level config; the setting is deliberately ignored in project files. The resolved profile and its source are printed in the startup summary.

**Git config protection.** Git runs code from a repository's hooks and from settings such as `core.fsmonitor`, `core.hooksPath`, `core.sshCommand`, filter drivers and aliases, and it does so whenever *you* use git there on the host: a commit, an IDE refreshing its status, a shell prompt showing the branch, T3 Code checkpointing after every turn. An agent that may write `.git/config` or `.git/hooks/` can therefore run commands outside the sandbox. By default every git repository inside a read-write mount (the working directory, nested repositories, submodules, a linked worktree's main repository, whitelisted repositories) gets:

- `config`, `config.worktree` and `hooks/` mounted read-only (a missing `hooks/` is created on the host first);
- the git directory mounted onto itself, so it cannot be renamed or replaced by a forged one;
- for linked worktrees, the `.git` file and the main repository's `worktrees/<name>/commondir` and `gitdir` read-only, so the worktree cannot be pointed at another repository.

Commits, branches, rebases, stashes, fetches and merges keep working. Commands that write the repository configuration fail inside the sandbox: `git config` without `--global`, `git remote add`, `git branch --set-upstream-to`, `git push -u`, `git submodule init`, `git lfs install` and hook managers that set `core.hooksPath` (husky, lefthook; their install step typically reports an error). Run them on the host, or pass the identity per command (`git -c user.email=… commit`). Changes made on the host to `.git/config` while a sandbox runs are only visible inside after a restart (the read-only mount keeps the file it started with). Disable with `--no-protect-git-config` or `protect_git_config: false` in the user-level config; project files cannot switch it off.

Not covered: code that lives in the working tree itself and runs when you use the project (hooks managed in the tree such as `.husky/`, `Makefile`, `package.json` scripts, `.envrc`, `.vscode/tasks.json`, a virtualenv's `activate`). Those are project files the agent is meant to edit, so review the diff before running them, as you would review any change it makes. Neither are git repositories the agent creates during the session: a new `.git` below the working directory (a nested clone, `git init`) is writable, so do not run git in such a directory on the host without looking at its `.git/config` first.

All files are merged together, allowing you to:
- Maintain a base configuration in the user-level file
- Add project-specific rules in `.ai-agent-sandbox/config.yaml` (can be committed to version control)
- Override with command-line flags
- Share configurations across teams and projects

### Environment Variables

**The host environment is not inherited.** Whatever launched the sandbox (your shell, a desktop session, an orchestrator) may have tokens, passwords or database URLs exported, so only a fixed allow-list reaches the agent: the session basics (`USER`, `SHELL`, `LANG`, `LC_*`, `TZ`, terminal and editor settings, `GIT_AUTHOR_*`/`GIT_COMMITTER_*`), proxy and CA certificate settings (the agent must reach its provider), toolchain locations (`JAVA_HOME`, `GOPATH`, `CARGO_HOME`, `NVM_DIR`, …) and the agents' own variables (`ANTHROPIC_*`, `CLAUDE_*`, `CLAUDECODE`, `OPENCODE_*`, `T3CODE_*` and Claude Code's settings such as `MAX_THINKING_TOKENS`). Everything else is removed, including the display and session bus addresses, `SSH_AUTH_SOCK`, `LD_PRELOAD`/`LD_LIBRARY_PATH`, `TMPDIR` and exported shell functions. `PATH`, `HOME`, `PWD` and `TERM` are set by the script. The list is deliberately not configurable; the startup summary names the hidden variables (names only, never values). See `HOST_ENV_ALLOWED` in the script for the full list.

The agent can read every variable it receives, so pass secrets deliberately and only those it needs. Credentials outside the allow-list, such as AWS credentials for Claude Code on Bedrock, `GOOGLE_APPLICATION_CREDENTIALS` for Vertex or provider keys for OpenCode (`OPENAI_API_KEY`, `OPENROUTER_API_KEY`, …), go into `env:` of your **user-level** config, with a reference to the host value:

```yaml
# ~/.config/ai-agent-sandbox/config.yaml
env:
  AWS_PROFILE: $AWS_PROFILE
  OPENROUTER_API_KEY: $OPENROUTER_API_KEY
```

Only user-level files and `--env` can reference hidden host variables. In project files (`.ai-agent-sandbox/`), `$VAR` resolves only to allowed host variables and earlier `env:` entries; other references stay empty with a warning, so a repository cannot pull `$GITHUB_TOKEN` into the sandbox.

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
- References resolve against the sandbox environment first (values set by earlier env entries or by the script itself, such as `PATH` and `HOME`), then fall back to the host environment (in project files only to allowed host variables, see above); undefined variables expand to empty.
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
3. ✅ **Secrets in the environment** - Only an allow-list of host environment variables reaches the agent (session basics, proxies, toolchain paths, the agents' own variables), so tokens exported in your shell stay outside; the SSH agent socket, display and session bus addresses are removed as well
4. ✅ **Home directory access** - Only minimal agent-specific config is exposed; starting the sandbox in the home directory itself (or a parent such as `/`) is refused unless `--allow-home-workdir` is given
5. ✅ **Credential separation** - With profiles, a project only sees the login, settings and memory of its own profile; the profile store itself is never visible inside the sandbox
6. ✅ **Code execution through git** - Hooks and configuration of every git repository in a writable mount are read-only, so the agent cannot plant commands that git would run on the host
7. ✅ **Self-modifying sandbox rules** - `.ai-agent-sandbox/` is mounted read-only so the agent cannot change the profile, whitelist or environment it runs with next time
8. ✅ **OpenCode 2 background server** - OpenCode 2 is started with `--standalone`, so the server that executes its tools runs inside the sandbox instead of the shared per-user service on the host
9. ✅ **Docker as a way out** - With `--enable-docker`, a filter refuses privileged containers, host namespaces, devices and other projects' containers, see [Docker support](#docker-support-testcontainers)
10. ✅ **Hardware and host details in /sys** - The sandbox gets an empty `/sys` with only CPU, NUMA and huge page information and its own cgroup, so disk serial numbers, MAC addresses, the host's network interfaces and the list of running applications (cgroup tree) stay hidden. Whitelist `/sys` or a subdirectory (e.g. `/sys/class/drm` for GPU tools) when a tool needs more
11. ✅ **Exploit-prone kernel interfaces** - A seccomp filter refuses keyrings, BPF, io_uring, userfaultfd, perf, module loading, terminal input injection, new user namespaces and mounts
12. ✅ **Host services and LAN** - In the default `isolated` network mode the host's loopback and private networks are unreachable, so a prompt-injected agent cannot probe local databases, dashboards, routers or other machines; only the ports and hosts you list are exposed

### Limitations and Considerations

1. ⚠️ **Internet access** - The agent reaches the internet (and therefore its LLM provider) in both `isolated` and `host` mode. `--network host` also gives it the host loopback and the LAN; `--network none` cuts everything but is only useful for offline runs.

2. ⚠️ **Blacklist uses tmpfs mounts** - Files matching blacklist patterns are hidden via tmpfs. This means:
   - Glob patterns are expanded at sandbox start time
   - Performance impact is minimal

3. ⚠️ **Working directory is still read-write** - The agent has full access to create/modify/delete files in the working directory (except blacklisted ones). This is necessary for coding agents to function.

4. ⚠️ **Shared kernel** - Agent processes run in their own PID, IPC, UTS, cgroup and (by default) network namespaces without capabilities and behind a syscall filter, but on the host kernel: a kernel exploit in a syscall the filter allows is an escape. Use a VM for untrusted code that may carry such exploits.

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

### "the working directory … is your home directory"
The sandbox was started in your home directory or a directory containing it (such as `/`). Change to the project directory first. If you really want the agent to have read-write access to your whole home directory, pass `--allow-home-workdir`. In T3 Code this happens with T3's built-in OpenCode provider; use OpenCode through T3's ACP provider instead (see [OpenCode in T3 Code](#opencode-in-t3-code-through-acp)).

### The sandbox uses the wrong Claude account
Check the `Profile:` line in the startup summary; it shows the profile and where it came from (`.ai-agent-sandbox/config.yaml`, `config.local.yaml`, `AI_AGENT_SANDBOX_PROFILE` or `--profile`). Use `--profile default` to force the host configuration, or `--list-profiles` to see which profiles are logged in.

`Error: profile mismatch` means the project pins a profile and `AI_AGENT_SANDBOX_PROFILE` names a different one (with `--strict-profile`, as in the T3 wrapper, a missing variable counts as `default`); in T3 Code, start the thread with the provider instance of the project's profile. Pass `--profile <name>` to run under another profile on purpose.

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

Run the test suite before sending changes (needs [bats-core](https://github.com/bats-core/bats-core) with bats-support, bats-assert and bats-file, e.g. `apt install bats bats-assert bats-support bats-file`):

```bash
tests/run.sh                # unit and script tests
tests/run.sh --integration  # also tests that start real bwrap sandboxes
```

Suggestions for improvements:
1. More sophisticated overlay filesystem handling
2. Integration with security audit tools
3. Preset profiles for common development stacks
4. Domain-level egress filtering (currently deliberately out of scope)

## Security Disclosure

If you find security issues with this sandboxing approach, please consider responsible disclosure practices.
