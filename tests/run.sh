#!/bin/bash
# Run the bats test suite.
#
# Usage: tests/run.sh [--integration] [bats options...]
#   Without options: unit and script tests (no real sandbox is started).
#   --integration:   also the tests that start real bwrap sandboxes; they
#                    need unprivileged user namespaces.
# shellcheck is run first when it is installed.

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

exec bats --recursive "$@" "${suites[@]}"
