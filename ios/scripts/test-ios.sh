#!/usr/bin/env bash
# Canonical iOS test entry point. Picks any available iPhone simulator and runs
# the NutriQuest scheme (NutriQuestTests + BattleKitTests).
#
# Usage:  ios/scripts/test-ios.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# Regenerate the app project if xcodegen is available; the committed
# .xcodeproj is a build artifact of project.yml, so regenerating keeps CI
# and local runs on the same graph. Skip silently when xcodegen is absent.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

UDID=$(xcrun simctl list devices available -j \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone") and not d.get("availabilityError"):
            print(d["udid"])
            sys.exit(0)
sys.exit("no available iPhone simulator")
')

echo "==> Testing on simulator $UDID"
xcodebuild test \
  -project NutriQuest.xcodeproj \
  -scheme NutriQuest \
  -destination "id=$UDID" \
  | tail -n 40
