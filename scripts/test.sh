#!/usr/bin/env bash
# Full check: lint, the test suite in two time zones (catches daylight-saving bugs), and the
# distribution/privacy check. Pass a filter to run only matching tests: scripts/test.sh Kills
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ $# -gt 0 ]]; then
	TZ=America/New_York .tools/bin/lua tests/run.lua "$1"
	exit
fi

scripts/lint.sh
for zone in UTC America/New_York; do
	echo "Tests (TZ=$zone):"
	TZ="$zone" .tools/bin/lua tests/run.lua
done
scripts/check-dist.sh
