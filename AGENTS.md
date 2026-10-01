# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

This is a bash-based sandboxing solution for running AI coding agents in isolated environments using **bubblewrap**. The script (`ai-agent-sandbox.sh`) provides filesystem isolation via whitelist/blacklist. Full network access (both local and internet) is enabled.

## Architecture

### Core Components

**Main Script: `ai-agent-sandbox.sh`**
- Single executable bash script that wraps an AI coding agent in a bubblewrap sandbox
- Implements two-tier filesystem access control, configured in `config.yaml` files:
  1. **Whitelist** (`whitelist:` key, `--whitelist-path[-rw]`): Absolute or relative paths the agent can read (relative paths resolved relative to working directory)
  2. **Blacklist** (`blacklist:` key, `--blacklist-path`): Relative working directory paths the agent cannot access
  - The user-level `config.yaml` is auto-generated with default whitelist/blacklist entries

### Key Design Patterns

**Filesystem Isolation Strategy (lines 236-262)**:
- Uses **tmpfs overlays** to hide blacklisted paths
- Working directory is bind-mounted read-write at line 234
- Blacklisted patterns expanded via `compgen -G` and hidden with `--tmpfs` mounts
- This means blacklist patterns are expanded at sandbox start time, not dynamically
- Unlike overlay filesystems, this doesn't copy files - just hides matching paths
- **Whitelist overrides**: Entries prefixed with `!` are applied after blacklist mounts to re-allow specific paths

**Network Configuration (lines 288-302)**:
- Full network access enabled by default
- Uses `--share-net` to share host network namespace
- Binds system `/etc/resolv.conf` and `/etc/hosts` for DNS resolution

**Docker Socket Proxy Integration**:
- Optional `--enable-docker` (or `-d`) starts a per-run socket proxy container
- Proxy socket is created at `$WORKING_DIR/.docker-proxy/docker.sock`
- Proxy restricts bind mounts to paths already accessible in the sandbox
- Allowed paths are collected from working directory, read-write whitelist entries, and `--bind` mounts in `BWRAP_ARGS`
- `DOCKER_HOST` is set inside sandbox to use the proxy socket

**Git Configuration Mount**:
- `~/.gitconfig` is bind-mounted read-only into the sandbox when it exists, so git identity and settings work inside
- Disable with `--no-gitconfig`

**GPG Agent Forwarding (`--gpg-agent`)**:
- Forwards the host `gpg-agent` instead of exposing keys, so commits can be GPG-signed inside the sandbox
- `validate_gpg_agent` runs on the host before the sandbox starts: it resolves the extra socket via `gpgconf --list-dirs agent-extra-socket` (launching the agent if needed), picks the public key(s) to expose (`git config user.signingkey` from the working directory, else every key with secret material listed by `gpg --list-secret-keys`), exports them into a temporary `mktemp -d` GnuPG home (`--no-autostart`, public keys only) and carries over their ownertrust. Missing tools, socket, or keys are fatal errors
- `mount_gpg_agent` adds the bwrap arguments: `--perms 0700 --dir` for `/run/user/<uid>` and `/run/user/<uid>/gnupg` (gpg only uses that socket directory when both are owned by the user with mode 0700, otherwise it falls back to `~/.gnupg`), a read-only bind of the host extra socket at `/run/user/<uid>/gnupg/S.gpg-agent`, a read-write bind of the temporary keyring at `~/.gnupg`, and `--unsetenv GNUPGHOME`
- The mounts are added right after the working-directory bind and **before** whitelist processing: bwrap does not change the mode of a directory that already exists, so a whitelisted path under `/run/user/<uid>` must not create that directory first
- The restricted extra socket allows signing but refuses secret key export and other privileged commands; pinentry runs on the host, so hardware keys keep prompting there
- The temporary keyring is removed by `cleanup_gpg_agent`, which runs from the `cleanup_sandbox` EXIT trap together with the Docker proxy cleanup

**Profiles (`--profile NAME`, `AI_AGENT_SANDBOX_PROFILE`, config key `profile`)**:
- A profile is a separate set of agent configuration, credentials and memory. Store: `PROFILES_DIR` (`${AI_AGENT_SANDBOX_PROFILES_DIR:-~/.local/share/ai-agent-sandbox/profiles}`, created 0700), one `<name>/home/` directory per profile that **mirrors the home directory layout**. `PROFILE_HOME` is `$HOME` for the reserved profile `default` (host configuration, the behaviour without `--profile`), otherwise `$PROFILES_DIR/<name>/home`
- `bind_profile_dir <rel>` / `bind_profile_file <rel> [initial]` bind `$PROFILE_HOME/<rel>` at `$HOME/<rel>` read-write, creating the source on first use. `mount_claude_config` uses them for `.claude/` and `.claude.json` (seeded with `{}` so onboarding and `/login` start cleanly; `.claude.json.backup` is bound when present) and adds `--unsetenv CLAUDE_CONFIG_DIR` so a host env var cannot bypass the mount. `mount_opencode_config` does the same for `.opencode.json`, `.config/opencode`, `.cache/opencode`, `.local/state/opencode`, `.local/share/opencode` and unsets the `XDG_*_HOME` variables; `~/.opencode` (the installation, contains the binary) stays shared from the host. Adding a new agent means adding its dotfile paths here
- `prepare_profile_home` creates the profile directory on first use and logs it; `validate_profile_name` enforces `^[A-Za-z0-9][A-Za-z0-9._-]*$`; `list_profiles` implements `--list-profiles` (exits before any side effects)
- Resolution: config files < `AI_AGENT_SANDBOX_PROFILE` < `--profile`. The env var deliberately beats project config so a repository cannot silently switch the user's credentials
- After whitelist processing, if `PROFILES_DIR` is visible through another mount (e.g. a whitelisted `~/.local/share`) it is covered with `--tmpfs` so no profile can read another profile's credentials. `warn_shadowed_binds` warns about whitelist mounts under `~/.claude` that the profile bind would hide
- `collect_allowed_mount_paths` (Docker) intentionally uses bind **sources**: the Docker daemon resolves host paths, so allowing destinations would let a non-default profile bind-mount the host's own `~/.claude`
- Fresh profiles are empty by design; seeding from the host is a manual `cp -a`

**Config file (`config.yaml`)**:
- Files: `DEFAULT_CONFIG_FILE` (`${AI_AGENT_SANDBOX_CONFIG:-~/.config/ai-agent-sandbox/config.yaml}`), `DEFAULT_CONFIG_LOCAL_FILE` (`${AI_AGENT_SANDBOX_CONFIG_LOCAL:-~/.config/ai-agent-sandbox/config.local.yaml}`), `.ai-agent-sandbox/config.yaml`, `.ai-agent-sandbox/config.local.yaml`, loaded in that order by `load_config_files`. Only the user-level `config.yaml` is auto-generated (see below); `config-example.yaml` documents every key
- **Parsed before the command-line loop** into the same variables the flags set, so flags always win (`--verbose` beats `quiet: true`, `--profile default` beats a project `profile:`). One-way flags therefore have counterparts: `--no-docker`, `--no-venv`, `--no-gpg-agent`, `--gitconfig`, `--no-protect-project-config`. `log_info` and `trim_whitespace` are defined above the loop for this reason; parser warnings are buffered in `CONFIG_LOG_MESSAGES` and flushed by `flush_config_log` once `QUIET` is known; fatal errors (`config_error`, e.g. an invalid boolean) exit immediately
- `parse_config_file` is a pure-bash state machine (`none`/`pending`/`list`/`env`/`skip`) supporting: `key: value` scalars (quoted or unquoted, `parse_yaml_scalar`; a `#` starts a comment only at the start of a value or after whitespace), block lists (`- item`), inline lists for list keys only when the value starts with `[` and ends with `]` (so globs like `/etc/java[0-9]*` stay scalars), `env:` block or inline mapping, `---`/`...`, CRLF, BOM and tab indentation. Everything else warns and is ignored
- Keys: `profile`, `agent`, `docker_image` (strings); `docker`, `venv`, `gpg_agent`, `gitconfig`, `quiet`, `protect_project_config` (bools, `parse_yaml_bool`); `whitelist` (→ `WHITELIST_ENTRIES`, processed by `process_whitelist_entry` after legacy whitelist files and before `--whitelist-path*`; does **not** set `EXPLICIT_WHITELIST`), `blacklist` (→ `BLACKLIST_PATHS`, does not set `EXPLICIT_BLACKLIST`), `agent_args` (→ `CONFIG_AGENT_ARGS`, prepended to `AGENT_ARGS` after the loop), `env` (`apply_config_env_item` pushes `KEY=<raw value>` to `ENV_VARS` so `parse_env_assignment` applies the `.env` quoting/expansion rules). `protect_project_config` is ignored with a warning when it comes from a project file. The removed keys `whitelist_files`/`blacklist_files`/`env_files` are a fatal `config_error` (silently ignoring `blacklist_files` would expose files), as are the removed flags `--whitelist`/`--blacklist`/`--env-path`
- `protect_project_config_dir` ro-binds `$WORKING_DIR/.ai-agent-sandbox` right after the working-directory bind (blacklist `/dev/null` binds nest on top), so the agent cannot rewrite the profile/whitelist/env that apply to the next run. Residual risk: the agent can create the directory if it does not exist

**Configuration Resolution Order (Multi-File Support)**:
1. **User-level files** (always included if they exist):
   - `~/.config/ai-agent-sandbox/config.yaml` and `config.local.yaml`
   - Environment variables `AI_AGENT_SANDBOX_CONFIG` and `AI_AGENT_SANDBOX_CONFIG_LOCAL` set the file locations
   - `config.yaml` is **auto-generated** (whitelist and/or blacklist sections) when neither YAML file nor any user-level legacy file exists and `EXPLICIT_WHITELIST`/`EXPLICIT_BLACKLIST` are not both set; only the sections not given explicitly are written. Generation happens after the command-line loop, so the new file is parsed then with its list entries prepended to `WHITELIST_ENTRIES`/`BLACKLIST_PATHS` (it holds only lists, so flags still win)
2. **Project-level files** (automatically included if they exist):
   - `.ai-agent-sandbox/config.yaml` and `.ai-agent-sandbox/config.local.yaml` (in working directory)
   - **Never auto-generated** - create manually for project-specific rules
3. **Command-line options** (`--whitelist-path[-rw]`, `--blacklist-path`, `--env`)
4. All sources are merged - all whitelist entries are allowed, all blacklist patterns are blocked

**Legacy files (deprecated)**:
- `whitelist.txt`, `blacklist.txt`, `.env`, `.env.local` in `~/.config/ai-agent-sandbox/` (`DEFAULT_*_FILE`, overridable via `AI_AGENT_SANDBOX_WHITELIST`/`_BLACKLIST`/`_ENV`/`_ENV_LOCAL`) and in `.ai-agent-sandbox/` (`PROJECT_*_FILE`)
- Decided **per level**: a level with `config.yaml` or `config.local.yaml` (`USER_HAS_YAML`/`PROJECT_HAS_YAML`) ignores its legacy files; a level without one still uses them (`WHITELIST_FILES`/`BLACKLIST_FILES`/`ENV_FILES` now only hold these legacy files; listed as "Deprecated Legacy Files" in the summary)
- `warn_legacy_files` prints a warning listing them in both cases (always, even with `--quiet`): "ignored" or "support will be dropped in a future release"

**Bubblewrap Namespace Setup (lines 191-205)**:
- `--unshare-all` creates isolated namespaces (PID, IPC, UTS, cgroup, etc.) but network is shared
- `--die-with-parent` ensures sandbox terminates if parent dies
- Minimal read-only mounts: `/proc`, `/dev`, `/sys`
- tmpfs for `/tmp` and `$HOME` (lines 201, 230)
- SSH agent is explicitly disabled via `--unsetenv SSH_AUTH_SOCK` (line 307)

**Claude Code Configuration Binding (lines 264-285)**:
- Native installs bind `~/.local/share/claude` read-write so downloaded versions persist
- Native installs mount `~/.local/bin` as an **overlayfs**: the host directory is the read-only lower layer and `~/.local/share/ai-agent-sandbox/claude-bin` is the writable upper layer (with `~/.local/share/ai-agent-sandbox/claude-work` as the overlay workdir). The in-sandbox updater's atomic launcher swap at `~/.local/bin/claude` lands in the upper layer and persists across runs, while other executables in `~/.local/bin` stay visible and the host directory is never modified
- `prepare_claude_native_install` re-syncs at every launch: the upper-layer launcher is kept only while strictly newer than the host's (an in-sandbox update the host hasn't caught up to); broken symlinks, stale whiteouts, and entries at or behind the host launcher are removed so the host launcher shows through the lower layer
- If bwrap lacks `--overlay` support, falls back to binding `claude-bin` over `~/.local/bin` (updates still persist, but other entries in `~/.local/bin` are hidden)
- Concurrent sandbox runs share the overlay upper/work dirs, which the kernel may refuse for simultaneous mounts
- Non-native `~/.local/bin/claude` installations remain read-only (the symlink/bind is skipped when `~/.local/bin` is already visible via a whitelist mount)
- `mount_claude_config` binds `$PROFILE_HOME/.claude/` and `$PROFILE_HOME/.claude.json` read-write at `~/.claude` / `~/.claude.json` (host paths for the `default` profile, profile store otherwise; created on first use, `.claude.json` seeded with `{}`)
- Preserves Claude-specific environment variables; unsets `CLAUDE_CONFIG_DIR`

## Development Commands

### Testing the Script

```bash
# Run in current directory with default settings
./ai-agent-sandbox.sh

# Test with a specific config file (fresh HOME, no user-level defaults)
AI_AGENT_SANDBOX_CONFIG=./config-example.yaml ./ai-agent-sandbox.sh --dry-run

# Test with additional paths for a single run
./ai-agent-sandbox.sh \
  --whitelist-path /opt/tools \
  --blacklist-path secrets/

# Pass arguments to underlying agent
./ai-agent-sandbox.sh -- --model claude-sonnet-4-5
```

### Script Validation

```bash
# Check bash syntax
bash -n ai-agent-sandbox.sh

# Check for common issues with shellcheck (if available)
shellcheck ai-agent-sandbox.sh
```

## Important Implementation Details

### Security Considerations

**Network Access**:
- Full network access is enabled (both local and internet)
- The sandbox shares the host network namespace via `--share-net`
- System DNS configuration is used for name resolution

**Pattern Matching Implementation** (find_matches function, lines 147-183):
- **Unified approach**: All pattern matching uses `find` command for consistency
- **Ant-style support**: Detects `**` patterns and handles them recursively
- Simple patterns: Uses `-name` or `-path` with `-maxdepth 1` for performance
- Recursive patterns: Uses `-name` or `-path` without depth limit
- Complex patterns (e.g., `**/dir/file`, `src/**/test/**/*.java`): each `**/` matches zero or more directories — expanded into all `*/`/empty variants and OR-ed in a single `find` expression
- Returns list of absolute paths matching the pattern

**Blacklist Implementation** (blacklist_pattern function, lines 246-271):
- **Multi-file processing**: Loops through all blacklist files in the array
- Uses `find_matches()` to expand patterns (supports ant-style `**`)
- Uses tmpfs mounts to hide directories (no file copying)
- Uses `/dev/null` binding to hide files
- Pattern matching happens against `$WORKING_DIR/$pattern`
- Non-matching patterns generate warnings but don't fail
- Missing blacklist files are skipped with warning (non-fatal)

**Whitelist Implementation** (whitelist_path function, lines 191-246):
- **Multi-file processing**: Loops through all whitelist files in the array
- Uses `find_matches()` to expand patterns (supports ant-style `**`)
- Environment variable expansion: `${line/#\~/$HOME}` and `${path//\$HOME/$HOME}`
- **Relative path support**: Paths not starting with `/`, `~`, or `$HOME` are converted to absolute by prepending `$WORKING_DIR`
- Extracts base directory from pattern for efficient find starting point
- Non-existent paths are skipped with warning, not errors
- Supports read-only (default) and read-write (`:rw` suffix) binding
- Missing whitelist files are skipped with warning, but at least one file must exist

### Configuration File Format

**Whitelist** (absolute or relative paths/patterns):
- One path or pattern per line
- Supports both absolute paths (e.g., `/usr/bin`) and relative paths (e.g., `data/`, `src/**/*.txt`)
- Relative paths are resolved relative to the working directory
- Environment variable expansion supported: `$HOME` or `~`
- **Blacklist override**: Prefix with `!` to re-allow a specific path that would otherwise be blocked by the blacklist
- **Pattern support**:
  - Simple glob: `*`, `?`, `[]` (e.g., `/etc/java*` or `*.json`)
  - **Ant-style recursive**: `**` for recursive matching (e.g., `/usr/**/lib64` or `src/**`)
  - Complex: Multiple `**` segments (e.g., `/opt/**/bin/**/tools` or `data/**/cache`)
- Patterns are expanded at sandbox start time using `find` command
- Literal paths are validated before binding - non-existent paths are skipped
- Read-write access: Append `:rw` to path/pattern (e.g., `/opt/cache:rw` or `data/:rw`)
- **Merged** from the `whitelist:` key of all config files, legacy whitelist files and `--whitelist-path*`; in files, comments start with `#` and empty lines are ignored

**Blacklist** (relative paths or patterns):
- Paths relative to working directory
- **Pattern support**:
  - Simple glob: `*`, `?` (e.g., `*.env`)
  - **Ant-style recursive**: `**` for recursive matching (e.g., `**/wallet.dat` blocks wallet.dat anywhere)
  - Complex: Multiple `**` segments (e.g., `**/test/**/secrets.json`)
- Patterns are expanded at sandbox start time using `find` command
- **Merged** from the `blacklist:` key of all config files, legacy blacklist files and `--blacklist-path`; in files, comments start with `#` and empty lines are ignored

**Common Ant-Style Pattern Examples**:
- `**/wallet.dat` - (blacklist) Matches wallet.dat in any subdirectory at any depth
- `**/.env` - (blacklist) Matches .env files anywhere in the tree
- `src/**/test/**/*.java` - (blacklist) Matches .java files in test directories under src
- `/usr/**/lib64` - (whitelist, absolute) Matches any lib64 directory under /usr
- `data/**` - (whitelist, relative) Matches all files under the data/ directory in working directory
- `src/**/*.json` - (whitelist, relative) Matches all .json files anywhere under src/ directory

## Modifying the Script

### Adding New Command-Line Options

Options are parsed in the `while` loop at lines 51-86. Patterns:

**Single-value option:**
```bash
--your-option)
    YOUR_VAR="$2"
    shift 2
    ;;
```

**Multi-value option (array):**
```bash
--your-option)
    YOUR_ARRAY+=("$2")
    EXPLICIT_YOUR_OPTION=true
    shift 2
    ;;
```

### Extending Bubblewrap Arguments

Add to `BWRAP_ARGS` array (initialized at line 191):
```bash
BWRAP_ARGS+=(--ro-bind /your/path /your/path)
```

### Network Configuration

Network setup is at lines 288-302:
- Uses `--share-net` to share host network namespace
- Binds `/etc/resolv.conf` for DNS resolution
- Binds `/etc/hosts` for hostname resolution

### Adding Claude Configuration Mounts

Claude Code needs specific paths (`mount_claude_config`):
- Launcher: `~/.local/bin/claude` (native installs: overlayfs with writable upper layer so updater launcher swaps persist; non-native: read-only) - shared by all profiles
- Versions: `~/.local/share/claude` (native installs, read-write) - shared by all profiles
- Config directory: `~/.claude/` (read-write, from `$PROFILE_HOME`)
- State file: `~/.claude.json` (read-write, from `$PROFILE_HOME`, auto-created with `{}` if missing)

When adding mounts, remember:
- Bind after `--tmpfs "$HOME"` or they'll be hidden
- Use `--ro-bind` for read-only, `--bind` for read-write
- Non-existent paths should be checked before binding
- Per-profile state must go through `bind_profile_dir` / `bind_profile_file` so it comes from `$PROFILE_HOME`; shared installation files are bound from `$HOME` directly

### Adding Config File Keys

Add the key to `is_config_list_key` (lists) and to `apply_config_list_item`, or to `apply_config_scalar` (scalars/bools). Config keys must set exactly the variables the equivalent flag sets; if the flag is one-way (only enables), add a `--no-...` counterpart so the command line can still override the file. Keys that must not be controllable from inside a project (security-relevant) follow the `protect_project_config` pattern: check `"$file" == "$PROJECT_CONFIG_DIR/"*` and warn. Document the key in `usage()`, `README.md` and `config-example.yaml`.

## Testing Checklist

When modifying the script:
1. Test with a fresh `$HOME` (should auto-generate `config.yaml` with whitelist and blacklist and use it in the same run)
2. Test with `--whitelist-path`/`--blacklist-path` on a fresh `$HOME` (should NOT auto-generate the corresponding section; both given → no file). `--whitelist`, `--blacklist`, `--env-path` and the `*_files` config keys must fail with an error
3. Test with legacy files only (used, "will be dropped" warning) and legacy files next to a `config.yaml`/`config.local.yaml` at the same level (ignored, "Ignoring" warning); check user and project level independently and that warnings show with `-q`
4. Test without project-level files (should work normally, no errors)
5. Test `whitelist:` entries in user and project config files (verify all paths are merged)
6. Test `blacklist:` entries in user and project config files (verify all patterns are merged)
7. Test with empty working directory
8. Test with glob patterns in blacklist (`*.env`, `.secrets/*`)
9. Test with environment variable expansion in whitelist (`$HOME/.local`, `~/.local`)
10. Test with relative paths in whitelist (`data/`, `src/**/*.txt`)
11. Test with ant-style patterns in both absolute and relative whitelist paths
12. Verify cleanup on clean exit and interrupt (Ctrl+C) - check for temp file leaks
13. Test with missing additional files (should skip with warning, not fail)
14. Test Claude Code can still access its config: check `~/.claude/` and `~/.claude.json`
15. Verify configuration summary shows all whitelist/blacklist files being used (user, project, and explicit)
16. If `--enable-docker` or `-d` is used, verify proxy starts and socket exists
17. Verify bind mount restrictions: allowed for working dir, denied for `/etc` and `~/.ssh`
18. Verify proxy cleanup on exit (no leftover container or socket file)
19. If `--gpg-agent` is used, verify `git commit -S` succeeds inside the sandbox, `gpg --export-secret-keys` fails with "Forbidden", and no `ai-agent-sandbox-gnupg.*` directory is left in `$TMPDIR` after exit
20. `--profile test --dry-run`: "Created new profile" is logged, `~/.claude` is empty and `~/.claude.json` is `{}` inside the sandbox, `CLAUDE_CONFIG_DIR` is unset, the store `~/.local/share/ai-agent-sandbox/profiles` is 0700 on the host and not visible inside the sandbox, and the host `~/.claude` is untouched. Without `--profile` the host configuration is used as before
21. Log in with `/login` inside a new profile, exit, rerun with the same profile: no login prompt, `profiles/<name>/home/.claude/.credentials.json` exists. `--list-profiles` marks it as logged in
22. Invalid profile names (`bad/name`, `../x`, `.hidden`) exit 1
23. Config precedence: user `config.yaml` < user `config.local.yaml` < project `config.yaml` < project `config.local.yaml` < `AI_AGENT_SANDBOX_PROFILE` < `--profile` (check the `Profile:` summary line); `docker: true` + `--no-docker` disables Docker; `whitelist`, `blacklist`, `env`, `agent_args` from config show up in mounts, environment and the final agent command
24. Parser edge cases: CRLF file, tab indentation, `docker: ture` (fatal), unknown key (warning), `"value # not a comment"`, `docker_image: ghcr.io/x:1`, a glob with `[` as a whitelist entry, `profile: ~` (unset)
25. A project config with a `whitelist:` list on a fresh `$HOME` still auto-generates the default user-level `config.yaml`
26. `.ai-agent-sandbox/` is read-only inside the sandbox (`touch .ai-agent-sandbox/x` fails) and blacklisted files in it are still hidden; `--no-protect-project-config` makes it writable again
27. `-d --profile test`: the proxy's allowed bind paths include the profile's `.claude` source path, not the host `~/.claude`

## Files in Repository

- `ai-agent-sandbox.sh` - Main executable script
- `README.md` - User-facing documentation
- `config-example.yaml` - Example config file (every key)
- `.gitignore` - Git ignore patterns
- `AGENTS.md` - Developer documentation (this file)

## Project-Level Configuration

Projects can include their own `config.yaml`/`config.local.yaml` in the `.ai-agent-sandbox/` directory:
- These files are automatically detected and used when present
- They are never auto-generated
- Ideal for version-controlled, team-shared configurations (`config.local.yaml` is for personal overrides and should be gitignored)
- Merged with the user-level config files and command-line options
- The directory is mounted read-only inside the sandbox by default (`protect_project_config`)
