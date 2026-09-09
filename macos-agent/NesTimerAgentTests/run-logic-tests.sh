#!/bin/bash
# Pure-logic test harness for the macOS agent.
#
# This Xcode project has no XCTest target (adding one means hand-editing
# project.pbxproj, the project's sharpest edge — see CLAUDE.md's "known
# sharp edges" and the shared-budget task briefs under .superpowers/sdd/).
# So pure-logic Swift files are compiled and run directly with `swiftc`
# instead of going through `xcodebuild test`.
#
# To add a case: add another `check(...)` call in the "Cases" section of the
# embedded main.swift below, and add the source file under test to SOURCES.
# The harness exits non-zero and prints "FAIL: <name>" for each failing case
# on the first failure.
#
# Usage: bash macos-agent/NesTimerAgentTests/run-logic-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(dirname "$SCRIPT_DIR")/NesTimerAgent"
SERVICES_DIR="$AGENT_DIR/Services"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

BINARY="$WORKDIR/logic-tests"

# Pure-logic source files under test. Tasks 9 and 10 add more here.
SOURCES=(
    "$SERVICES_DIR/RemainingTime.swift"
)

cat > "$WORKDIR/main.swift" <<'SWIFT'
import Foundation

var failures = 0

func check(_ name: String, _ actual: Double, _ expected: Double) {
    if actual != expected {
        failures += 1
        FileHandle.standardError.write("FAIL: \(name) — expected \(expected), got \(actual)\n".data(using: .utf8)!)
    } else {
        print("PASS: \(name)")
    }
}

func check(_ name: String, _ actual: LimitSource, _ expected: LimitSource) {
    if actual != expected {
        failures += 1
        FileHandle.standardError.write("FAIL: \(name) — expected \(expected), got \(actual)\n".data(using: .utf8)!)
    } else {
        print("PASS: \(name)")
    }
}

// MARK: - Cases

check(
    "testRemainingUsesSharedBudgetWhenNoCap",
    RemainingTime.minutes(limitMinutes: 120, childUsedMinutes: 45, deviceCapMinutes: nil, deviceUsedMinutes: 45),
    75.0
)

check(
    "testRemainingCountsTimeSpentOnOtherDevices",
    // 120 min budget, 80 used total (this device's own usedMinutesToday
    // includes time reported from other devices), 30 used on this device.
    RemainingTime.minutes(limitMinutes: 120, childUsedMinutes: 80, deviceCapMinutes: nil, deviceUsedMinutes: 30),
    40.0
)

check(
    "testRemainingIsClampedToZero",
    RemainingTime.minutes(limitMinutes: 120, childUsedMinutes: 150, deviceCapMinutes: nil, deviceUsedMinutes: 150),
    0.0
)

// MARK: - Report

if failures > 0 {
    FileHandle.standardError.write("\n\(failures) test case(s) failed.\n".data(using: .utf8)!)
    exit(1)
} else {
    print("\nAll logic tests passed.")
    exit(0)
}
SWIFT

if ! swiftc -O "${SOURCES[@]}" "$WORKDIR/main.swift" -o "$BINARY" 2> "$WORKDIR/compile.log"; then
    echo "Compilation failed:" >&2
    cat "$WORKDIR/compile.log" >&2
    exit 1
fi

"$BINARY"
exit $?
