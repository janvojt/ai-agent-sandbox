#!/usr/bin/env bats
# Unit tests of the small validators and helpers: network mode, host port,
# profile name, dedupe_array, path_is_within, trim_whitespace, display_path.

setup() {
    load ../test_helper/common
    setup_test_env
    load_sandbox_script
}

# --- validate_network_mode ----------------------------------------------------

@test "validate_network_mode accepts isolated, host and none" {
    local mode
    for mode in isolated host none; do
        run validate_network_mode "$mode"
        assert_success
    done
}

@test "validate_network_mode rejects unknown, empty and differently cased modes" {
    local mode
    for mode in full "" Host bridge "host "; do
        run validate_network_mode "$mode"
        assert_failure
    done
}

# --- validate_host_port -------------------------------------------------------

@test "validate_host_port accepts ports 1 to 65535" {
    local port
    for port in 1 22 3773 65535; do
        run validate_host_port "$port"
        assert_success
    done
}

@test "validate_host_port rejects 0, out-of-range and non-numeric ports" {
    local port
    for port in 0 65536 70000 123456 abc "" -1 "80 " 8o; do
        run validate_host_port "$port"
        assert_failure
    done
}

@test "validate_host_port accepts an ascending or single-port range" {
    run validate_host_port 8000-8100
    assert_success
    run validate_host_port 5432-5432
    assert_success
    run validate_host_port 1-65535
    assert_success
}

@test "validate_host_port rejects descending, open and out-of-range ranges" {
    local spec
    for spec in 8100-8000 8000- -8000 0-10 65535-70000 1-2-3; do
        run validate_host_port "$spec"
        assert_failure
    done
}

# --- validate_profile_name ----------------------------------------------------

@test "validate_profile_name accepts letters, digits, dots, underscores and dashes" {
    local name
    for name in default work Work2 a 1 my-profile my_profile v1.2 a.b-c_d; do
        PROFILE="$name"
        run validate_profile_name
        assert_success
        assert_output ""
    done
}

@test "validate_profile_name exits 1 for invalid names" {
    local name
    for name in bad/name ../x .hidden "" -dash _under "has space" 'a$b'; do
        PROFILE="$name"
        run validate_profile_name
        assert_failure 1
        assert_output --partial "Invalid profile name '$name'"
    done
}

# --- dedupe_array -------------------------------------------------------------

@test "dedupe_array removes duplicates and keeps the first occurrence order" {
    local -a items=(b a b c a "with space" "with space")
    dedupe_array items
    assert_equal "${#items[@]}" 4
    assert_equal "${items[0]}" b
    assert_equal "${items[1]}" a
    assert_equal "${items[2]}" c
    assert_equal "${items[3]}" "with space"
}

@test "dedupe_array leaves an empty array empty" {
    local -a items=()
    dedupe_array items
    assert_equal "${#items[@]}" 0
}

@test "dedupe_array keeps entries that differ only in a trailing slash" {
    local -a items=(/opt/a /opt/a/ /opt/a)
    dedupe_array items
    assert_equal "${items[*]}" "/opt/a /opt/a/"
}

# --- path_is_within -----------------------------------------------------------

@test "path_is_within is true for the directory itself and paths below it" {
    run path_is_within /home/u /home/u
    assert_success
    run path_is_within /home/u/project /home/u
    assert_success
    run path_is_within /home/u/a/b/c /home/u
    assert_success
}

@test "path_is_within is false for siblings sharing a name prefix and for parents" {
    run path_is_within /home/user2 /home/user
    assert_failure
    run path_is_within /home /home/u
    assert_failure
    run path_is_within /other /home/u
    assert_failure
}

# --- trim_whitespace ----------------------------------------------------------

@test "trim_whitespace strips leading and trailing spaces and tabs" {
    run trim_whitespace $'  \t value with  inner  spaces \t '
    assert_output "value with  inner  spaces"
}

@test "trim_whitespace returns an empty line for blank input" {
    run trim_whitespace $' \t '
    assert_success
    assert_output ""
}

@test "trim_whitespace leaves an already trimmed value unchanged" {
    run trim_whitespace "value"
    assert_output "value"
}

# --- display_path -------------------------------------------------------------

@test "display_path shows the working directory as ." {
    run display_path "$WORKING_DIR"
    assert_output "."
}

@test "display_path shows paths below the working directory relative to it" {
    run display_path "$WORKING_DIR/src/main.sh"
    assert_output "src/main.sh"
}

@test "display_path leaves paths outside the working directory absolute" {
    run display_path /etc/passwd
    assert_output /etc/passwd
    run display_path "${WORKING_DIR}2/file"
    assert_output "${WORKING_DIR}2/file"
}
