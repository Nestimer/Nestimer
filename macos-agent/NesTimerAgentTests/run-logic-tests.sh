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
# APIClient.swift is Foundation-only (ServerPolicy/ScheduledActivity/UsageReport + the
# APIClient class itself use only Foundation types — no AppKit/UIKit or other
# app-target-only dependency), so it compiles standalone here just like RemainingTime.swift.
SOURCES=(
    "$SERVICES_DIR/RemainingTime.swift"
    "$SERVICES_DIR/APIClient.swift"
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

func check(_ name: String, _ actual: Int?, _ expected: Int?) {
    if actual != expected {
        failures += 1
        FileHandle.standardError.write("FAIL: \(name) — expected \(String(describing: expected)), got \(String(describing: actual))\n".data(using: .utf8)!)
    } else {
        print("PASS: \(name)")
    }
}

func fail(_ name: String, _ message: String) {
    failures += 1
    FileHandle.standardError.write("FAIL: \(name) — \(message)\n".data(using: .utf8)!)
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

check(
    "testDeviceCapBindsBeforeSharedBudget",
    // 120 min budget with 20 used overall, but only 60 allowed here and 55 already spent.
    RemainingTime.minutes(limitMinutes: 120, childUsedMinutes: 20, deviceCapMinutes: 60, deviceUsedMinutes: 55),
    5.0
)

check(
    "testSharedBudgetBindsWhenCapIsLooser",
    RemainingTime.minutes(limitMinutes: 120, childUsedMinutes: 115, deviceCapMinutes: 60, deviceUsedMinutes: 10),
    5.0
)

// testSharedBudgetBindsWhenCapIsLooser (above) passes even if the cap logic were deleted
// entirely, because the budget is already the binding constraint at those values (5.0
// either way). This case is chosen so the cap genuinely is looser (80 remaining from the
// cap vs. 30 from the budget) AND deviceUsedMinutes (20) is deliberately far from
// childUsedMinutes (90) — the exact shape of Task 8's deliberate no-op regression, where
// deviceUsedMinutes was accidentally passed the same value as childUsedMinutes. If that
// aliasing regressed (deviceUsedMinutes read as childUsedMinutes = 90), fromCap would become
// 100 - 90 = 10, which is LESS than the budget's 30 and would flip the answer to 10 — so
// this case fails loudly under that regression instead of silently agreeing with it.
check(
    "testCapPresentAndLooserStillReadsRealDeviceUsage",
    RemainingTime.minutes(limitMinutes: 120, childUsedMinutes: 90, deviceCapMinutes: 100, deviceUsedMinutes: 20),
    30.0
)

check(
    "testBindingLimitIsReportedForTheLockScreen_deviceCap",
    RemainingTime.binding(limitMinutes: 120, childUsedMinutes: 20, deviceCapMinutes: 60, deviceUsedMinutes: 55),
    LimitSource.deviceCap
)

check(
    "testBindingLimitIsReportedForTheLockScreen_sharedBudget",
    RemainingTime.binding(limitMinutes: 120, childUsedMinutes: 115, deviceCapMinutes: 60, deviceUsedMinutes: 10),
    LimitSource.sharedBudget
)

// MARK: - ServerPolicy decode compatibility
//
// This is the highest-stakes guarantee in the shared-budget change: a server that hasn't
// been upgraded yet omits device_used_minutes/device_cap_minutes entirely. If decoding ever
// throws on that response, the agent gets no config at all and the device goes unmanaged.

do {
    // Legacy payload: a pre-upgrade server response with BOTH new fields absent.
    let legacyJSON = """
    {"downtime_enabled": true, "downtime_start": "22:00", "downtime_end": "08:00",
     "screen_time_enabled": true, "screen_time_limit_minutes": 120,
     "used_minutes_today": 10.0}
    """.data(using: .utf8)!

    let policy = try JSONDecoder().decode(ServerPolicy.self, from: legacyJSON)
    check("testMissingFieldsDecodeToSafeDefaults_deviceUsedMinutes", policy.deviceUsedMinutes, 0)
    check("testMissingFieldsDecodeToSafeDefaults_deviceCapMinutes", policy.deviceCapMinutes, nil)
} catch {
    fail("testMissingFieldsDecodeToSafeDefaults", "decode threw \(error) instead of defaulting")
}

do {
    // Upgraded-server payload: both new fields present, should round-trip to their real values.
    let upgradedJSON = """
    {"downtime_enabled": true, "downtime_start": "22:00", "downtime_end": "08:00",
     "screen_time_enabled": true, "screen_time_limit_minutes": 120,
     "used_minutes_today": 10.0, "device_used_minutes": 7.5, "device_cap_minutes": 60}
    """.data(using: .utf8)!

    let policy = try JSONDecoder().decode(ServerPolicy.self, from: upgradedJSON)
    check("testPresentFieldsDecodeCorrectly_deviceUsedMinutes", policy.deviceUsedMinutes, 7.5)
    check("testPresentFieldsDecodeCorrectly_deviceCapMinutes", policy.deviceCapMinutes, 60)
} catch {
    fail("testPresentFieldsDecodeCorrectly", "decode threw \(error)")
}

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
