#!/bin/bash
# Run the bats test suite.
#
# Usage: tests/run.sh [--integration] [bats options...]
#   Without options: unit and script tests (no real sandbox is started).
#   --integration:   also the tests that start real bwrap sandboxes; they
#                    need unprivileged user namespaces.
# Runs shellcheck first when it is installed. Test files run in parallel
# when GNU parallel is installed (pass --jobs 1 to run them sequentially).

set -euo pipefail

cd "$(dirname "$0")"

suites=(unit script)
if [[ "${1:-}" == --integration ]]; then
    suites+=(integration)
    shift
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x ../ai-agent-sandbox.sh
fi

# Run the test files in parallel when GNU parallel is available (bats needs
# it for --jobs) and no --jobs/-j was given; every test has its own
# directories, so they do not interfere
jobs=()
if [[ " $* " != *" --jobs "* && " $* " != *" -j "* ]] \
    && parallel --version 2>/dev/null | grep -q 'GNU parallel'; then
    jobs=(--jobs "$(nproc 2>/dev/null || echo 4)")
fi

exec bats --recursive "${jobs[@]}" "$@" "${suites[@]}"
