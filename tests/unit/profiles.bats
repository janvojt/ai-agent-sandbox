#!/usr/bin/env bats
# Unit tests of the profile store and the per-profile agent configuration
# mounts: profile home resolution, the 0700 store, profile binds, the shared
# skills overlay and the Claude Code / OpenCode configuration mounts.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
    BWRAP_ARGS=()
    stub_bwrap
    BWRAP_BIN="$STUB_DIR/bwrap"
    LOG_FILE="$BATS_TEST_TMPDIR/log"
}

# Usage: use_profile <name>; sets PROFILE and PROFILE_HOME like the main section
use_profile() {
    PROFILE="$1"
    resolve_profile_home
}

# Replace the stub bwrap with one whose --help lacks overlay support
stub_bwrap_without_overlay() {
    stub_command bwrap "echo 'usage: bwrap [OPTIONS...] [--] COMMAND [ARGS...]'"
}

# --- resolve_profile_home / prepare_profile_home / list_profiles ------------------

@test "resolve_profile_home: the default profile uses the host home" {
    use_profile default
    assert_equal "$PROFILE_HOME" "$HOME"
}

@test "resolve_profile_home: a named profile lives in the profile store" {
    use_profile work
    assert_equal "$PROFILE_HOME" "$PROFILES_DIR/work/home"
    assert_equal "$PROFILES_DIR" "$HOME/.local/share/ai-agent-sandbox/profiles"
}

@test "resolve_profile_home: AI_AGENT_SANDBOX_PROFILES_DIR moves the store" {
    export AI_AGENT_SANDBOX_PROFILES_DIR="$BATS_TEST_TMPDIR/store"
    load_sandbox_script
    use_profile work
    assert_equal "$PROFILE_HOME" "$BATS_TEST_TMPDIR/store/work/home"
}

@test "prepare_profile_home: creates the profile home and a 0700 store" {
    use_profile work
    run prepare_profile_home
    assert_success
    assert_output --partial "Created new profile 'work'"
    assert_dir_exists "$PROFILES_DIR/work/home"
    run stat -c %a "$PROFILES_DIR"
    assert_output 700
}

@test "prepare_profile_home: an existing profile is left alone" {
    use_profile work
    mkdir -p "$PROFILES_DIR/work"
    run prepare_profile_home
    assert_success
    assert_output ""
    assert_dir_not_exists "$PROFILES_DIR/work/home"
}

@test "prepare_profile_home: does nothing for the default profile" {
    use_profile default
    run prepare_profile_home
    assert_success
    assert_output ""
    assert_dir_not_exists "$PROFILES_DIR"
}

@test "list_profiles: only the default profile without a store" {
    run list_profiles
    assert_success
    assert_output "default (host configuration)"
}

@test "list_profiles: lists profiles and marks logged-in Claude profiles" {
    mkdir -p "$PROFILES_DIR/alpha/home/.claude" "$PROFILES_DIR/beta/home"
    : > "$PROFILES_DIR/alpha/home/.claude/.credentials.json"
    : > "$PROFILES_DIR/not-a-dir"
    run list_profiles
    assert_success
    assert_output "default (host configuration)
alpha (claude: logged in)
beta"
}

# --- bind_profile_dir / bind_profile_file -----------------------------------------

@test "bind_profile_dir: creates the source on first use and binds it read-write" {
    use_profile work
    run bind_profile_dir .config/opencode
    assert_output --partial "Created and mounted ~/.config/opencode"
    bind_profile_dir .config/opencode 2>/dev/null
    assert_dir_exists "$PROFILE_HOME/.config/opencode"
    assert_equal "${BWRAP_ARGS[*]}" "--bind $PROFILE_HOME/.config/opencode $HOME/.config/opencode"
}

@test "bind_profile_dir: an existing source is mounted as is" {
    use_profile work
    mkdir -p "$PROFILE_HOME/.claude"
    : > "$PROFILE_HOME/.claude/settings.json"
    run bind_profile_dir .claude
    assert_output --partial "Mounted ~/.claude (read-write)"
    refute_output --partial "Created"
    assert_file_exists "$PROFILE_HOME/.claude/settings.json"
}

@test "bind_profile_dir: the default profile binds the host directory onto itself" {
    use_profile default
    bind_profile_dir .claude 2>/dev/null
    assert_equal "${BWRAP_ARGS[*]}" "--bind $HOME/.claude $HOME/.claude"
}

@test "bind_profile_file: creates the source with the initial content" {
    use_profile work
    bind_profile_file .claude.json '{}' 2>/dev/null
    assert_file_exists "$PROFILE_HOME/.claude.json"
    run cat "$PROFILE_HOME/.claude.json"
    assert_output '{}'
    assert_equal "${BWRAP_ARGS[*]}" "--bind $PROFILE_HOME/.claude.json $HOME/.claude.json"
}

@test "bind_profile_file: creates an empty file without initial content" {
    use_profile work
    bind_profile_file .opencode.json 2>/dev/null
    assert_file_exists "$PROFILE_HOME/.opencode.json"
    assert_file_empty "$PROFILE_HOME/.opencode.json"
}

@test "bind_profile_file: never overwrites an existing file" {
    use_profile work
    mkdir -p "$PROFILE_HOME"
    printf '{"a":1}' > "$PROFILE_HOME/.claude.json"
    bind_profile_file .claude.json '{}' 2>/dev/null
    run cat "$PROFILE_HOME/.claude.json"
    assert_output '{"a":1}'
}

# --- overlay_shared_profile_dir ---------------------------------------------------

@test "overlay_shared_profile_dir: overlays host skills under the profile's own" {
    use_profile work
    mkdir -p "$HOME/.claude/skills/a"
    overlay_shared_profile_dir .claude/skills claude-skills 2>/dev/null
    assert_equal "${BWRAP_ARGS[*]}" \
        "--overlay-src $HOME/.claude/skills --overlay $PROFILE_HOME/.claude/skills $PROFILES_DIR/work/overlay-work/claude-skills $HOME/.claude/skills"
    assert_dir_exists "$PROFILE_HOME/.claude/skills"
    assert_dir_exists "$PROFILES_DIR/work/overlay-work/claude-skills"
}

@test "overlay_shared_profile_dir: the workdir is outside the profile home" {
    use_profile work
    mkdir -p "$HOME/.claude/skills"
    overlay_shared_profile_dir .claude/skills claude-skills 2>/dev/null
    local work="${BWRAP_ARGS[4]}"
    assert_equal "${work#"$PROFILE_HOME"/}" "$work"
}

@test "overlay_shared_profile_dir: a symlinked host directory is resolved for the lower layer" {
    use_profile work
    mkdir -p "$BATS_TEST_TMPDIR/dotfiles/skills" "$HOME/.claude"
    ln -s "$BATS_TEST_TMPDIR/dotfiles/skills" "$HOME/.claude/skills"
    overlay_shared_profile_dir .claude/skills claude-skills 2>/dev/null
    assert_args_contain BWRAP_ARGS --overlay-src "$BATS_TEST_TMPDIR/dotfiles/skills"
}

@test "overlay_shared_profile_dir: no-op for the default profile" {
    use_profile default
    mkdir -p "$HOME/.claude/skills"
    overlay_shared_profile_dir .claude/skills claude-skills
    assert_equal "${#BWRAP_ARGS[@]}" 0
}

@test "overlay_shared_profile_dir: no-op when skill sharing is off" {
    use_profile work
    SHARE_SKILLS=false
    mkdir -p "$HOME/.claude/skills"
    overlay_shared_profile_dir .claude/skills claude-skills
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_dir_not_exists "$PROFILES_DIR/work/overlay-work"
}

@test "overlay_shared_profile_dir: no-op when the host directory does not exist" {
    use_profile work
    overlay_shared_profile_dir .claude/skills claude-skills
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_dir_not_exists "$PROFILE_HOME/.claude/skills"
}

@test "overlay_shared_profile_dir: warns and adds nothing without overlay support" {
    use_profile work
    stub_bwrap_without_overlay
    mkdir -p "$HOME/.claude/skills"
    run overlay_shared_profile_dir .claude/skills claude-skills
    assert_success
    assert_output --partial "Not sharing host ~/.claude/skills with profile 'work' (bubblewrap lacks overlay support)"
    overlay_shared_profile_dir .claude/skills claude-skills 2>/dev/null
    assert_equal "${#BWRAP_ARGS[@]}" 0
}

# --- mount_claude_config ----------------------------------------------------------

@test "mount_claude_config: the default profile binds the host configuration" {
    use_profile default
    mkdir -p "$HOME/.claude/skills"
    mount_claude_config 2>/dev/null
    assert_equal "${BWRAP_ARGS[*]}" \
        "--bind $HOME/.claude $HOME/.claude --bind $HOME/.claude.json $HOME/.claude.json --unsetenv CLAUDE_CONFIG_DIR"
    run cat "$HOME/.claude.json"
    assert_output '{}'
}

@test "mount_claude_config: a named profile binds its own configuration with shared skills" {
    use_profile work
    mkdir -p "$HOME/.claude/skills/a"
    echo host > "$HOME/.claude.json"
    mount_claude_config 2>/dev/null
    assert_equal "${BWRAP_ARGS[*]}" \
        "--bind $PROFILE_HOME/.claude $HOME/.claude --overlay-src $HOME/.claude/skills --overlay $PROFILE_HOME/.claude/skills $PROFILES_DIR/work/overlay-work/claude-skills $HOME/.claude/skills --bind $PROFILE_HOME/.claude.json $HOME/.claude.json --unsetenv CLAUDE_CONFIG_DIR"
    run cat "$PROFILE_HOME/.claude.json"
    assert_output '{}'
    run cat "$HOME/.claude.json"
    assert_output host
    run stat -c %a "$PROFILES_DIR"
    assert_output 700
}

@test "mount_claude_config: a named profile never binds the host's ~/.claude" {
    use_profile work
    mkdir -p "$HOME/.claude"
    mount_claude_config 2>/dev/null
    refute_args_contain BWRAP_ARGS --bind "$HOME/.claude" "$HOME/.claude"
    refute_args_contain BWRAP_ARGS --bind "$HOME/.claude.json" "$HOME/.claude.json"
}

@test "mount_claude_config: binds .claude.json.backup when it exists" {
    use_profile work
    mkdir -p "$PROFILE_HOME"
    : > "$PROFILE_HOME/.claude.json.backup"
    mount_claude_config 2>/dev/null
    assert_args_contain BWRAP_ARGS --bind "$PROFILE_HOME/.claude.json.backup" "$HOME/.claude.json.backup"
}

@test "mount_claude_config: warns about whitelist binds hidden by the profile mount" {
    use_profile work
    BWRAP_ARGS=(--ro-bind "$HOME/.claude/agents" "$HOME/.claude/agents")
    run mount_claude_config
    assert_output --partial "Mount at $HOME/.claude/agents is shadowed by the profile mount at $HOME/.claude"
}

# --- mount_opencode_external_skills / mount_opencode_config -----------------------

@test "mount_opencode_external_skills: the default profile binds an existing host directory" {
    use_profile default
    mkdir -p "$HOME/.agents/skills"
    mount_opencode_external_skills .agents/skills agents-skills 2>/dev/null
    assert_equal "${BWRAP_ARGS[*]}" "--bind $HOME/.agents/skills $HOME/.agents/skills"
}

@test "mount_opencode_external_skills: the default profile never creates a missing host directory" {
    use_profile default
    mount_opencode_external_skills .agents/skills agents-skills
    assert_equal "${#BWRAP_ARGS[@]}" 0
    assert_dir_not_exists "$HOME/.agents"
}

@test "mount_opencode_external_skills: the default profile skips a directory already visible" {
    use_profile default
    mkdir -p "$HOME/.agents/skills"
    BWRAP_ARGS=(--ro-bind "$HOME/.agents" "$HOME/.agents")
    run mount_opencode_external_skills .agents/skills agents-skills
    assert_output --partial "~/.agents/skills already visible via existing mount"
    mount_opencode_external_skills .agents/skills agents-skills 2>/dev/null
    assert_equal "${#BWRAP_ARGS[@]}" 3
}

@test "mount_opencode_external_skills: a named profile gets its own directory with host skills shared" {
    use_profile work
    mkdir -p "$HOME/.agents/skills/x"
    mount_opencode_external_skills .agents/skills agents-skills 2>/dev/null
    assert_equal "${BWRAP_ARGS[*]}" \
        "--bind $PROFILE_HOME/.agents/skills $HOME/.agents/skills --overlay-src $HOME/.agents/skills --overlay $PROFILE_HOME/.agents/skills $PROFILES_DIR/work/overlay-work/agents-skills $HOME/.agents/skills"
}

@test "mount_opencode_external_skills: a named profile keeps its own skills without a host directory" {
    use_profile work
    mount_opencode_external_skills .agents/skills agents-skills 2>/dev/null
    assert_equal "${BWRAP_ARGS[*]}" "--bind $PROFILE_HOME/.agents/skills $HOME/.agents/skills"
    assert_dir_exists "$PROFILE_HOME/.agents/skills"
    assert_dir_not_exists "$HOME/.agents"
}

@test "mount_opencode_config: the default profile binds host directories and unsets overrides" {
    use_profile default
    mkdir -p "$HOME/.opencode/bin" "$HOME/.claude/skills"
    mount_opencode_config 2>/dev/null
    assert_args_contain BWRAP_ARGS --bind "$HOME/.opencode" "$HOME/.opencode"
    assert_args_contain BWRAP_ARGS --bind "$HOME/.opencode.json" "$HOME/.opencode.json"
    local rel
    for rel in .config/opencode .cache/opencode .local/state/opencode .local/share/opencode .claude/skills; do
        assert_args_contain BWRAP_ARGS --bind "$HOME/$rel" "$HOME/$rel"
    done
    refute_args_contain BWRAP_ARGS --bind "$HOME/.agents/skills"
    refute_args_contain BWRAP_ARGS --overlay-src
    local var
    for var in XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_DATA_HOME OPENCODE_CONFIG_DIR OPENCODE_DB; do
        assert_args_contain BWRAP_ARGS --unsetenv "$var"
    done
}

@test "mount_opencode_config: a named profile binds its own state and shares host skills" {
    use_profile work
    mkdir -p "$HOME/.opencode" "$HOME/.config/opencode/skills/s" "$HOME/.claude/skills/c" "$HOME/.agents/skills/g"
    mount_opencode_config 2>/dev/null
    # The installation stays shared
    assert_args_contain BWRAP_ARGS --bind "$HOME/.opencode" "$HOME/.opencode"
    assert_args_contain BWRAP_ARGS --bind "$PROFILE_HOME/.opencode.json" "$HOME/.opencode.json"
    local rel
    for rel in .config/opencode .cache/opencode .local/state/opencode .local/share/opencode .claude/skills .agents/skills; do
        assert_args_contain BWRAP_ARGS --bind "$PROFILE_HOME/$rel" "$HOME/$rel"
        refute_args_contain BWRAP_ARGS --bind "$HOME/$rel" "$HOME/$rel"
    done
    assert_args_contain BWRAP_ARGS --overlay-src "$HOME/.config/opencode/skills" \
        --overlay "$PROFILE_HOME/.config/opencode/skills" "$PROFILES_DIR/work/overlay-work/opencode-skills" "$HOME/.config/opencode/skills"
    # ~/.claude/skills shares upper layer and workdir with Claude Code
    assert_args_contain BWRAP_ARGS --overlay-src "$HOME/.claude/skills" \
        --overlay "$PROFILE_HOME/.claude/skills" "$PROFILES_DIR/work/overlay-work/claude-skills" "$HOME/.claude/skills"
    assert_args_contain BWRAP_ARGS --overlay-src "$HOME/.agents/skills" \
        --overlay "$PROFILE_HOME/.agents/skills" "$PROFILES_DIR/work/overlay-work/agents-skills" "$HOME/.agents/skills"
    assert_args_contain BWRAP_ARGS --unsetenv OPENCODE_CONFIG_DIR --unsetenv OPENCODE_DB
}

@test "mount_opencode_config: the skills overlay nests on top of the config bind" {
    use_profile work
    mkdir -p "$HOME/.config/opencode/skills"
    mount_opencode_config 2>/dev/null
    local i bind_at=-1 overlay_at=-1
    for i in "${!BWRAP_ARGS[@]}"; do
        if [[ "${BWRAP_ARGS[i]}" == --bind && "${BWRAP_ARGS[i+2]}" == "$HOME/.config/opencode" ]]; then
            bind_at=$i
        elif [[ "${BWRAP_ARGS[i]}" == --overlay && "${BWRAP_ARGS[i+3]}" == "$HOME/.config/opencode/skills" ]]; then
            overlay_at=$i
        fi
    done
    (( bind_at >= 0 && overlay_at > bind_at ))
}
