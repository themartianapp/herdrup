#!/usr/bin/env bash
# Runs one simulator shard of the CI device suite. ci.yml runs the shards as
# parallel jobs; each job has already built the app and test bundles into .build-dd
# (build-for-testing) and exported IPHONE_UDID / IPAD_UDID.
#
#   iphone-terminal  TERMINAL_CLASSES, then ChatViewTests and PagingTests in rounds of
#                    their own, on iPhone
#   iphone-app       HerdrFontTests, then StatusMotionTests in its own round, then
#                    every other HerdrUITests class on iPhone, then the SwiftTerm UIKit API
#                    tests on iPhone
#   ipad             iPad-specific rounds, then the SwiftTerm UIKit API tests on iPad
#   settings-build   optimized simulator build; CI caches its products before testing
#   settings-gram    iPad Settings resize/resume regression using that Distribution build
#                    with the device-sized stack (herdrup#416), even on cache hits; then
#                    GramTests on the iPhone with the Debug build
#   focused          ONLY_SUITE on ONLY_DEVICE (manual dispatch)
#
# The iPhone rounds are complementary BY CONSTRUCTION: iphone-terminal runs exactly
# TERMINAL_CLASSES plus ChatViewTests and PagingTests and settings-gram runs GramTests,
# while iphone-app skips those same identifiers, so a new test class lands in iphone-app
# without anyone listing it. A misspelled or renamed entry would silently drop that class, so
# iphone-terminal fails unless its result bundles show every listed class executed tests.
set -uo pipefail

shard="${1:?usage: ui-shard.sh iphone-terminal|iphone-app|ipad|settings-build|settings-gram|focused}"
TERMINAL_CLASSES=(TerminalControlTests TerminalResizeTests TerminalSearchTests TerminalSelectionTests)
mkdir -p TestReceipts

TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
if [ -z "$TIMEOUT_BIN" ]; then
  echo "::error::no timeout binary; per-suite budgets would be unenforceable"
  exit 1
fi

PROJECT=(-project Herdr.xcodeproj -scheme Herdr
  -derivedDataPath .build-dd -clonedSourcePackagesDirPath SourcePackages
  CODE_SIGNING_ALLOWED=NO)

# Build the optimized simulator products; tests use the generated .xctestrun below.
# Only the selected simulator architecture runs this test. Distribution otherwise builds
# an unused x86_64 copy on the arm64 hosted runner (baseline 38829646885).
SETTINGS_PROJECT=(-project Herdr.xcodeproj -scheme Herdr -configuration Distribution
  -derivedDataPath .build-dd-settings-stack -clonedSourcePackagesDirPath SourcePackages
  ENABLE_TESTABILITY=YES 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG'
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO)

recorder=
# BOUNDED: SIGINT asks the recorder to finish the video; one that never exits is killed
# after 60 s. Run 40728450580's iPad shard (Xcode 27.1) logged "simulator ... failed to
# become ready within 5m" for iPadResize while recordVideo ran, then nothing for four hours
# until the 255m job timeout: its receipts hold a 0-byte terminal-resize-iPad.mp4 next to
# an unfinished terminal-resize-iPad.mp4.sb-* temp file, so the recorder never exited and
# the old bare `wait` here never returned.
stop_recording() {
  if [ -n "$recorder" ]; then
    kill -INT "$recorder" 2>/dev/null || true
    local waited=0
    while kill -0 "$recorder" 2>/dev/null && [ "$waited" -lt 60 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$recorder" 2>/dev/null; then
      echo "::warning::screen recorder $recorder did not stop within 60 s of SIGINT; killed (video incomplete)"
      kill -KILL "$recorder" 2>/dev/null || true
    fi
    wait "$recorder" 2>/dev/null || true
    recorder=
  fi
}
trap stop_recording EXIT

# Bound the entire boot request + readiness wait, not just xcodebuild. A stuck
# CoreSimulator must leave time for receipt upload. TERM gets 15 s before KILL.
# First-boot data migration took 5m41s in run 38916529804. Each device's first (cold)
# boot gets 10m; later readiness checks of the same device keep the shorter 5m.
# Per device, because settings-gram cold-boots the iPad and then the iPhone.
cold_booted=" "
# Devices that bootstatus reported ready earlier in this job. Do not repeat bootstatus
# for a still-booted device: on Xcode 27, with the screen recorder running, the second
# readiness check of an iPad that had just been reported ready hung its whole 5m in three
# focused iPad runs in a row (40828227115, 40834877074 with empty logs; 40839462725, whose
# stamped log shows the hang is the first command, `simctl list devices`, and a 60 s
# bounded `simctl list` before it timed out too). This cache is not current device state:
# run 40994033942 saw cached-ready iPhones shut down before later installs. Reuse the
# bounded service probe below before returning readiness to any caller.
ready_devices=" "
# After bootstatus reports a device ready (and the screen recorder starts), CoreSimulator
# can stop answering every simctl request for minutes on Xcode 27: the ipad shard of
# 40827550901 waited 3.5 min for its second readiness check to print anything; focused
# iPad runs waited past 5m in that check (above) and, with the check skipped, in
# `simctl install` (40844294026, and 40822219713 / 40823615938 with no recorder at all).
# So readiness includes waiting until the service answers a cheap query, before install
# or any other simulator operation. Each probe is bounded so a wedged one is abandoned,
# and the busiest processes are logged while the service is silent. Free when it answers.
service_settle_budget=900
wait_for_simulator_service() {
  local log="$1" udid="$2" start probe=0 inventory
  simulator_device_state=
  start=$(date +%s)
  while :; do
    probe=$((probe + 1))
    if inventory=$("$TIMEOUT_BIN" --signal=TERM --kill-after=5s 30s xcrun simctl list devices --json 2>>"$log"); then
      echo "$(date -u +%FT%TZ) CoreSimulator answered after $(( $(date +%s) - start )) s ($probe probes)" | tee -a "$log"
      if ! simulator_device_state=$(printf '%s\n' "$inventory" | python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["devices"]
    if not isinstance(devices, dict) or any(not isinstance(group, list) for group in devices.values()):
        raise ValueError("invalid devices inventory")
    matches = [device for group in devices.values() for device in group if device.get("udid") == sys.argv[1]]
    if len(matches) != 1:
        raise ValueError("target missing or duplicated in device inventory")
    device = matches[0]
    if device.get("isAvailable") is not True:
        raise ValueError("target is unavailable")
    state = device.get("state")
    if state not in ("Booted", "Shutdown"):
        raise ValueError("target has unsupported or missing state: %r" % state)
    print(state)
except (ValueError, KeyError, TypeError, AttributeError) as error:
    print("invalid simulator inventory for %s: %s" % (sys.argv[1], error), file=sys.stderr)
    sys.exit(1)
' "$udid" 2>>"$log"); then
        echo "::error::cannot determine current simulator state for $udid; see $log"
        return 1
      fi
      echo "$(date -u +%FT%TZ) $udid current state: $simulator_device_state" >>"$log"
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "$service_settle_budget" ]; then
      echo "::error::CoreSimulator did not answer simctl within ${service_settle_budget}s of the boot; see $log"
      return 1
    fi
    {
      echo "$(date -u +%FT%TZ) probe $probe: simctl list did not answer in 30 s; busiest processes:"
      ps -axo pid,etime,pcpu,rss,comm | sort -k3 -nr | head -8
    } >>"$log" 2>&1
  done
}
boot_simulator() {
  local udid="$1" log="$2" status=0 budget=10m simulator_device_state=
  echo "$(date -u +%FT%TZ) checking simulator readiness for $udid" >"$log"
  case "$ready_devices" in *" $udid "*)
    # Reuse the service-settle query instead of trusting historical bootstatus.
    # Its state result is caller-local, never a second persistent readiness cache.
    if ! wait_for_simulator_service "$log" "$udid"; then
      ready_devices="${ready_devices/ $udid / }"
      return 1
    fi
    if [ "$simulator_device_state" = Booted ]; then
      echo "$(date -u +%FT%TZ) $udid is still Booted: no boot, no bootstatus" | tee -a "$log"
      return 0
    fi
    ready_devices="${ready_devices/ $udid / }"
    echo "$(date -u +%FT%TZ) $udid is Shutdown; invalidated cached readiness" >>"$log"
    ;;
  esac
  case "$cold_booted" in *" $udid "*) budget=5m ;; esac
  cold_booted="$cold_booted$udid "
  # Each step is stamped in the log before it starts: simctl's own output is block-buffered
  # into the pipe and lost when the timeout kills it, which left only empty logs to read.
  "$TIMEOUT_BIN" --signal=TERM --kill-after=15s "$budget" bash -c '
    # Boot only a device that is not booted; bootstatus is the readiness authority.
    # On Xcode 27, `simctl boot` of an iPad that had just finished booting hung with no
    # output: run 40728450580 (iPadResize-boot.log empty, "failed to become ready within
    # 5m") and run 40774306376 with no recorder running ("IPAD-REC-DIAG norec-boot
    # exit=124 secs=307"), while bootstatus on the same iPad answered "Device already
    # booted". Xcode 26 rejected the same call at once ("Unable to boot device in current
    # state: Booted"), which this used to rely on.
    echo "$(date -u +%FT%TZ) simctl list devices"
    if ! xcrun simctl list devices | grep -F "($1)" | grep -qF "(Booted)"; then
      echo "$(date -u +%FT%TZ) simctl boot $1"
      xcrun simctl boot "$1" || true
    fi
    echo "$(date -u +%FT%TZ) simctl bootstatus $1 -b"
    exec xcrun simctl bootstatus "$1" -b
  ' _ "$udid" 2>&1 | tee -a "$log" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "::error::simulator $udid failed to become ready within $budget (exit $status); see $log"
    return 1
  fi
  # Bootstatus alone does not prove CoreSimulator is answering or that the target
  # stayed booted. Settle once here for all consumers, not again during install.
  if ! wait_for_simulator_service "$log" "$udid" || [ "$simulator_device_state" != Booted ]; then
    echo "::error::simulator $udid is not confirmed Booted after boot; see $log"
    return 1
  fi
  ready_devices="$ready_devices$udid "
}

# Installs the app under test after boot and before xcodebuild's first launch, and fails
# the round if the install fails (herdrup#418). Run 39991292867: on a just cold-booted
# iPhone the first three GramTests timed out acquiring XCTest's background assertion while
# the home screen still showed the app as "Installing…". This only installs: nothing
# launches the app, so each test's first launch is still the real XCTest launch.
# xcodebuild installs the same build again; that install finds the system settled.
# Every round that launches an app through XCUIApplication on a booted simulator does this:
# run_suite (the Debug app) and the iPad Settings regression (the Distribution app).
# swiftterm_api runs package unit tests in a test host, with no app for XCUITest to launch.
# Callers must obtain current readiness through boot_simulator before using simctl.
APP_UNDER_TEST=.build-dd/Build/Products/Debug-iphonesimulator/Herdr.app
SETTINGS_APP_UNDER_TEST=.build-dd-settings-stack/Build/Products/Distribution-iphonesimulator/Herdr.app
install_app_under_test() {
  local udid="$1" log="$2" app="${3:-$APP_UNDER_TEST}" bundle_id start
  if [ ! -d "$app" ]; then
    echo "::error::app under test not found at $app"
    return 1
  fi
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist") || {
    echo "::error::cannot read CFBundleIdentifier from $app"
    return 1
  }
  start=$(date +%s)
  echo "$(date -u +%FT%TZ) install $bundle_id from $app on $udid" >"$log"
  if ! "$TIMEOUT_BIN" --signal=TERM --kill-after=15s 5m \
      xcrun simctl install "$udid" "$app" >>"$log" 2>&1; then
    echo "::error::installing $bundle_id on $udid failed or timed out; see $log"
    return 1
  fi
  echo "$(date -u +%FT%TZ) simctl install returned after $(( $(date +%s) - start )) s" >>"$log"
  # simctl install returns when installd is done; the container proves the system has it.
  # 5m, as the install. Run 40728450580 (Xcode 27.1, first install after a cold boot) logged
  # only the install line on two iPhones before "no app container ... (or the query timed
  # out)", 169 s and 204 s after the install began. The query prints the path or an error,
  # so an empty log means the old 1m bound killed it while the simulator was still busy;
  # the same run's other cold-boot install took 186 s against 26-84 s on Xcode 26.
  if ! "$TIMEOUT_BIN" --signal=TERM --kill-after=15s 5m \
      xcrun simctl get_app_container "$udid" "$bundle_id" app >>"$log" 2>&1; then
    echo "::error::$bundle_id has no app container on $udid after install (or the query timed out); see $log"
    return 1
  fi
  echo "$(date -u +%FT%TZ) installed in $(( $(date +%s) - start )) s" | tee -a "$log"
}

# Prints one -only-testing argument per failed test case in an .xcresult. A runner that
# crashes while bootstrapping is recorded as a failed "Test Case" named like
# "HerdrUITests-Runner (21391) encountered an error" (run 40728450580, iPhoneStatusMotion);
# passed to xcodebuild, it failed with "Unknown build action '(21391)'". Only Class/method
# identifiers are tests to rerun.
failed_tests() {
  xcrun xcresulttool get test-results tests --path "$1" 2>/dev/null | python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
def walk(node, bundle):
    if node.get("nodeType") in ("UI test bundle", "Unit test bundle"):
        bundle = node.get("name")
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed" and bundle:
        identifier = node["nodeIdentifier"].removesuffix("()")
        if re.fullmatch(r"\w+/\w+", identifier):
            print("-only-testing:%s/%s" % (bundle, identifier))
    for child in node.get("children", []):
        walk(child, bundle)
for node in data.get("testNodes", []):
    walk(node, None)
'
}

run_suite() {
  local label="$1" udid="$2" budget="$3"
  shift 3
  local status=0
  # Boot outside the test deadline. Booting during the build was measured to slow both.
  boot_simulator "$udid" "TestReceipts/$label-boot.log" || return 1
  install_app_under_test "$udid" "TestReceipts/$label-install.log" || return 1
  # A WALL-CLOCK BOUND PER INVOCATION, so one wedged case cannot eat the job budget
  # and take the receipt upload down with it. Per-case allowances make xcodebuild
  # fail a stuck test with diagnostics instead of blocking to the deadline.
  "$TIMEOUT_BIN" --signal=INT "$budget" xcodebuild test-without-building "${PROJECT[@]}" \
      -destination "platform=iOS Simulator,id=$udid" \
      -parallel-testing-enabled NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 300 \
      -maximum-test-execution-time-allowance 600 \
      -resultBundlePath "TestReceipts/$label-first.xcresult" \
      "$@" 2>&1 | tee "TestReceipts/$label-first.log" | xcbeautify || status=$?
  # The first case's result and time is the first real XCTest launch after install.
  grep -m1 -E "^Test Case '.*' (passed|failed|skipped) \(" "TestReceipts/$label-first.log" \
    | sed 's/^/first test after install: /' >>"TestReceipts/$label-install.log" || true
  [ "$status" -eq 0 ] && return 0
  stop_recording
  if [ "$status" -eq 124 ] || [ "$status" -eq 130 ]; then
    # A timeout is a failure on its own evidence; a rerun would spend the budget again.
    echo "::error::$label exceeded its ${budget} budget; see TestReceipts/$label-first.log"
    return 1
  fi
  echo "::error::$label first run failed; the failure stands. Rerunning only the failed tests for raw diagnostics"
  local failed
  failed=$(failed_tests "TestReceipts/$label-first.xcresult")
  if [ -z "$failed" ]; then
    echo "::warning::$label: no failed test case recorded in the result bundle; no diagnostic rerun"
    return 1
  fi
  echo "$failed" | tee "TestReceipts/$label-diagnostic-selection.txt"
  # Diagnostics only: the failed tests usually rerun in 1-3 min. A short cap keeps a
  # pathological rerun from eating the job budget that the receipt upload needs.
  # shellcheck disable=SC2086 # one -only-testing argument per line
  "$TIMEOUT_BIN" --signal=INT 10m xcodebuild test-without-building "${PROJECT[@]}" \
      -destination "platform=iOS Simulator,id=$udid" \
      -parallel-testing-enabled NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 300 \
      -maximum-test-execution-time-allowance 600 \
      -resultBundlePath "TestReceipts/$label-diagnostic.xcresult" \
      $failed 2>&1 | tee "TestReceipts/$label-diagnostic.log" >/dev/null || true
  return 1
}

# Fails unless every class named after the bundle executed at least one test in it.
check_classes_ran() {
  local bundle="$1"
  shift
  xcrun xcresulttool get test-results tests --path "$bundle" 2>/dev/null |
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    print("::error::no readable result bundle to check " + ", ".join(sys.argv[1:]) + " against")
    sys.exit(1)
ran = set()
def walk(node, suite):
    if node.get("nodeType") == "Test Suite":
        suite = node.get("name")
    if node.get("nodeType") == "Test Case" and node.get("result") != "Skipped" and suite:
        ran.add(suite)
    for child in node.get("children", []):
        walk(child, suite)
for node in data.get("testNodes", []):
    walk(node, None)
missing = [name for name in sys.argv[1:] if name not in ran]
for name in missing:
    print(f"::error::{name} executed no tests in this round; the listed name no longer matches a class, so that class falls through to the iphone-app catch-all round")
sys.exit(1 if missing else 0)
' "$@"
}

# Herdrup Desktop's agent-list, Gram and Settings reference screenshots on one iPad.
# Each class keeps its own bounded round as the reference set grows. The app starts from a
# fresh install (no UserDefaults left by earlier rounds), the device is dark, and the status
# bar is pinned: 9:41, full battery, charged, no cellular, three Wi-Fi bars. simctl takes
# only a plain time here: it rejected both ISO date-times (`…Z` and `…+00:00`) as "non-ISO"
# on this image (runs 40681584968, 40685403456). The override is listed into the receipts,
# which design/reference/agent-list/manifest.json records, and cleared afterwards so later
# rounds on the device see the real status bar.
DESKTOP_REFERENCE_STATUS_BAR=(--time 9:41 --batteryLevel 100 --batteryState charged
  --cellularMode notSupported --wifiBars 3)
DESKTOP_REFERENCE_CLASSES=(DesktopReferenceShots DesktopGramReferenceShots DesktopSettingsReferenceShots DesktopDetailReferenceShots)
desktop_reference_round() {
  local label="$1" udid="$2" bundle_id class round status=0
  shift 2
  local classes=("${DESKTOP_REFERENCE_CLASSES[@]}")
  if [ "$#" -gt 0 ]; then classes=("$@"); fi
  boot_simulator "$udid" "TestReceipts/$label-boot.log" || return 1
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_UNDER_TEST/Info.plist") || return 1
  xcrun simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" appearance dark || return 1
  xcrun simctl status_bar "$udid" override "${DESKTOP_REFERENCE_STATUS_BAR[@]}" || return 1
  {
    echo "xcrun simctl status_bar <udid> override ${DESKTOP_REFERENCE_STATUS_BAR[*]}"
    xcrun simctl status_bar "$udid" list
  } | tee "TestReceipts/$label-status-bar.txt"
  # Match focused iPad runs: record before installation, including simulator failures
  # that happen before XCTest can attach its own recording.
  xcrun simctl io "$udid" recordVideo "TestReceipts/$label-reference.mp4" \
    > "TestReceipts/$label-reference-video.log" 2>&1 &
  recorder=$!
  for class in "${classes[@]}"; do
    round="$label-${class//\//-}"
    run_suite "$round" "$udid" 15m "-only-testing:HerdrUITests/$class" || status=1
    check_classes_ran "TestReceipts/$round-first.xcresult" "${class%%/*}" || status=1
  done
  stop_recording
  xcrun simctl status_bar "$udid" clear || true
  xcrun simctl ui "$udid" appearance light || true
  return "$status"
}

swiftterm_api() {
  local device="$1" udid="$2"
  (
    cd Vendor/SwiftTerm || exit 1
    xcodebuild -list -json > ../../TestReceipts/SwiftTermSchemes.json
    scheme=$(python3 - <<'PY'
import json
with open("../../TestReceipts/SwiftTermSchemes.json") as source:
    result = json.load(source)
schemes = next((result[key]["schemes"] for key in ("workspace", "project") if key in result), [])
for candidate in ("SwiftTerm", "SwiftTerm-Package"):
    if candidate in schemes:
        print(candidate)
        break
else:
    raise SystemExit("::error::SwiftTerm package test scheme unavailable")
PY
    ) || exit 1
    # Build outside the timed test window.
    if ! "$TIMEOUT_BIN" --signal=INT 10m xcodebuild build-for-testing -scheme "$scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath ../../.build-dd-swiftterm \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "../../TestReceipts/SwiftTermUIKit-$device-build.log" | xcbeautify; then
      echo "::error::SwiftTerm test build failed; see TestReceipts/SwiftTermUIKit-$device-build.log"
      exit 1
    fi
    label="SwiftTermUIKit-$device"
    # No install_app_under_test here: these are package unit tests, and no XCUIApplication
    # launches an app, so the cold-boot install race (#418) does not apply.
    boot_simulator "$udid" "../../TestReceipts/$label-boot.log" || exit 1
    if ! "$TIMEOUT_BIN" --signal=INT 15m xcodebuild test-without-building -scheme "$scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -parallel-testing-enabled NO \
        -test-timeouts-enabled YES \
        -only-testing:SwiftTermTests/TerminalViewGeometryTests \
        -derivedDataPath ../../.build-dd-swiftterm \
        -resultBundlePath "../../TestReceipts/$label-first.xcresult" \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "../../TestReceipts/$label-first.log" | xcbeautify; then
      echo "::error::$label first run failed; collecting raw diagnostics without erasing failure"
      boot_simulator "$udid" "../../TestReceipts/$label-diagnostic-boot.log" || exit 1
      "$TIMEOUT_BIN" --signal=INT 15m xcodebuild test-without-building -scheme "$scheme" \
          -destination "platform=iOS Simulator,id=$udid" \
          -parallel-testing-enabled NO \
          -test-timeouts-enabled YES \
          -only-testing:SwiftTermTests/TerminalViewGeometryTests \
          -derivedDataPath ../../.build-dd-swiftterm \
          -resultBundlePath "../../TestReceipts/$label-diagnostic.xcresult" \
          CODE_SIGNING_ALLOWED=NO 2>&1 | tee "../../TestReceipts/$label-diagnostic.log" >/dev/null || true
      exit 1
    fi
  )
}

failed=0
case "$shard" in
  iphone-terminal)
    only=()
    for class in "${TERMINAL_CLASSES[@]}"; do only+=("-only-testing:HerdrUITests/$class"); done
    run_suite iPhoneTerminal "$IPHONE_UDID" 40m "${only[@]}" || failed=1
    check_classes_ran TestReceipts/iPhoneTerminal-first.xcresult "${TERMINAL_CLASSES[@]}" || failed=1
    # GramTests run in settings-gram: after #445 this shard had ~40 min of tests against
    # ~26 (iphone-app) and ~24 (ipad), and settings-stack finished in ~13 min (runs
    # 39128731625, 39132955146, 39137628334).
    # ChatViewTests (#485, ~3.5 min on a hosted runner) run here: in the app round they
    # pushed iPhoneApp to 29 min of tests against its 30 m budget, which run 39930335960
    # exceeded. This shard had ~18 min of tests in that run against 40 m.
    run_suite iPhoneChat "$IPHONE_UDID" 10m -only-testing:HerdrUITests/ChatViewTests || failed=1
    check_classes_ran TestReceipts/iPhoneChat-first.xcresult ChatViewTests || failed=1
    # Chat UX owns a separate round so its keyboard/history checks cannot consume
    # the general app suite's existing 30-minute deadline. 20m, as on iPad: round 4 added
    # three cases (colours 82 s, thought 36 s, SVG 50 s in run 40537708095) to the 478 s
    # the suite took in run 40470715282, and that run spent 874 s on 17 of its 19 cases,
    # so 15m ran out while the last case was launching.
    run_suite iPhoneChatUX "$IPHONE_UDID" 20m -only-testing:HerdrUITests/ChatUXSmokeTests || failed=1
    check_classes_ran TestReceipts/iPhoneChatUX-first.xcresult ChatUXSmokeTests || failed=1
    # PagingTests (~4.3 min) run here too: every class in the app round slowed together
    # from run to run (23.7, 26.9 and 29.0 min of tests in runs 39938860577, 39954390114
    # and 39966934030), and 39966934030 ran out of the 30 m on the last class. This shard
    # had ~26 min of tests in its slowest recent run (39944992620) against 40 m + 10 m.
    run_suite iPhonePaging "$IPHONE_UDID" 10m -only-testing:HerdrUITests/PagingTests || failed=1
    check_classes_ran TestReceipts/iPhonePaging-first.xcresult PagingTests || failed=1
    ;;
  iphone-app)
    run_suite font-contract "$IPHONE_UDID" 10m -only-testing:HerdrFontTests || failed=1
    # StatusMotionTests photograph shapes over time and wait out tab switches (~3.5 min on
    # a slow hosted runner): with them in the app round, #433's run 38703928881 ran out of
    # its 30 m on the last class.
    run_suite iPhoneStatusMotion "$IPHONE_UDID" 10m -only-testing:HerdrUITests/StatusMotionTests || failed=1
    # Keep both classes, each within the existing 10m deadline. In 41177678247 the
    # six folder cases passed in 449s, leaving insufficient time for NeedsYou.
    run_suite iPhoneAgentFolders "$IPHONE_UDID" 10m -only-testing:HerdrUITests/AgentFoldersTests || failed=1
    check_classes_ran TestReceipts/iPhoneAgentFolders-first.xcresult AgentFoldersTests || failed=1
    run_suite iPhoneNeedsYouPill "$IPHONE_UDID" 10m -only-testing:HerdrUITests/NeedsYouPillTests || failed=1
    check_classes_ran TestReceipts/iPhoneNeedsYouPill-first.xcresult NeedsYouPillTests || failed=1
    # Update-card scenarios take ~4 minutes (243 s in run 40900275118). Keeping them
    # in iPhoneApp repeatedly exhausted its 30-minute cap before the last classes.
    run_suite iPhoneServerUpdate "$IPHONE_UDID" 10m -only-testing:HerdrUITests/ServerUpdateUITests || failed=1
    check_classes_ran TestReceipts/iPhoneServerUpdate-first.xcresult ServerUpdateUITests || failed=1
    skip=(-skip-testing:HerdrUITests/GramTests -skip-testing:HerdrUITests/StatusMotionTests
      -skip-testing:HerdrUITests/ChatViewTests -skip-testing:HerdrUITests/ChatUXSmokeTests -skip-testing:HerdrUITests/PagingTests
      -skip-testing:HerdrUITests/AgentFoldersTests -skip-testing:HerdrUITests/NeedsYouPillTests
      -skip-testing:HerdrUITests/ServerUpdateUITests)
    for class in "${DESKTOP_REFERENCE_CLASSES[@]}"; do skip+=("-skip-testing:HerdrUITests/$class"); done
    for class in "${TERMINAL_CLASSES[@]}"; do skip+=("-skip-testing:HerdrUITests/$class"); done
    # 40m: on the Xcode 27 image every class ran slower. Run 40728450580 logged "iPhoneApp
    # exceeded its 30m budget" on its 79th case; its 69 cases that passed there and on
    # Xcode 26 took 1738 s against 1351 s in run 40686976698 (x1.29), whose whole round
    # took 25 min, so a green round now needs ~33 min.
    run_suite iPhoneApp "$IPHONE_UDID" 40m -only-testing:HerdrUITests "${skip[@]}" || failed=1
    swiftterm_api iPhone "$IPHONE_UDID" || failed=1
    # Herdrup Desktop's 11-inch references; the 13-inch ones run in the ipad shard. This
    # shard had the most room (31 min against the ipad shard's 60 in run 40655871305).
    xcrun simctl shutdown "$IPHONE_UDID" >/dev/null 2>&1 || true
    desktop_reference_round iPad11DesktopReference "$IPAD11_UDID" || failed=1
    ;;
  ipad)
    boot_simulator "$IPAD_UDID" TestReceipts/iPadRecording-boot.log || exit 1
    # Parallel test clones are disabled, so the video records the tested device.
    xcrun simctl io "$IPAD_UDID" recordVideo TestReceipts/terminal-resize-iPad.mp4 \
      > TestReceipts/terminal-resize-iPad-video.log 2>&1 &
    recorder=$!
    run_suite iPadResize "$IPAD_UDID" 25m \
      -only-testing:HerdrUITests/TerminalResizeTests \
      -only-testing:HerdrUITests/DuoTransitionTests || failed=1
    stop_recording
    if [ ! -s TestReceipts/terminal-resize-iPad.mp4 ]; then
      echo "::warning::iPad video unavailable; consult recording log and xcresult screenshots"
    fi
    # The iPhone shards keep their coordinate/keyboard receipts; these rounds cover
    # iPad's hardware-keyboard prerequisite and the iPad-only detail column.
    # Run 38862083708/4 spent 14m on passing cases before the old 15m cap cut off launch.
    # Leave room for the remaining cases; individual test limits and failures are unchanged.
    run_suite iPadControl "$IPAD_UDID" 20m -only-testing:HerdrUITests/TerminalControlTests || failed=1
    run_suite iPadSelectAgent "$IPAD_UDID" 5m -only-testing:HerdrUITests/SelectAgentFieldTests || failed=1
    # The needs-you pill pinned at the top of the sidebar (#551).
    run_suite iPadNeedsYouPill "$IPAD_UDID" 5m -only-testing:HerdrUITests/NeedsYouPillTests || failed=1
    # Agent folders in the sidebar (#552): a closed folder's counts, open in place, kept open.
    run_suite iPadAgentFolders "$IPAD_UDID" 5m \
      -only-testing:HerdrUITests/AgentFoldersTests/testClosedFolderShowsWaitingCountAndOpensOnTap || failed=1
    # 20m: the chat-width tests (#523, ~100 s on iPad) took run 40289743354's slow runner to
    # 848 s of tests, past the old 15m once xcodebuild's own start-up was added.
    run_suite iPadChatUX "$IPAD_UDID" 20m -only-testing:HerdrUITests/ChatUXSmokeTests || failed=1
    check_classes_ran TestReceipts/iPadChatUX-first.xcresult ChatUXSmokeTests || failed=1
    # Gram's column width (#541): handles, drag, snap, reset and relaunch on the iPad. The
    # iPhone half (no handles) runs in the iPhone app round.
    run_suite iPadGramColumn "$IPAD_UDID" 10m -only-testing:HerdrUITests/GramColumnTests || failed=1
    check_classes_ran TestReceipts/iPadGramColumn-first.xcresult GramColumnTests || failed=1
    # Herdrup Desktop's 13-inch references, before AgentListChrome leaves a window behind.
    desktop_reference_round iPadDesktopReference "$IPAD_UDID" || failed=1
    # Last of the app rounds: AgentListChromeTests shrinks the app into a window on purpose,
    # and iPadOS keeps that window for later launches, even across a reinstall. Run
    # 40537708095 (and 40552658219, which uninstalled the app after this round) ran
    # NeedsYouPill and the first ChatUX cases in a 715-722 pt window: no room for the chat
    # column and pixel probes off the window, failing four ChatUX cases that pass full screen.
    run_suite iPadAgentListChrome "$IPAD_UDID" 5m -only-testing:HerdrUITests/AgentListChromeTests || failed=1
    swiftterm_api iPad "$IPAD_UDID" || failed=1
    ;;
  settings-build)
    # Build before booting: compiler and simulator compete for the hosted runner's CPUs.
    "$TIMEOUT_BIN" --signal=INT --kill-after=15s 40m \
        xcodebuild build-for-testing "${SETTINGS_PROJECT[@]}" \
        -destination "platform=iOS Simulator,id=$IPAD_UDID" \
        -only-testing:HerdrUITests/SettingsTests/testCompactSettingsSurviveResizeAndResume \
        2>&1 | tee TestReceipts/settings-device-stack-build.log | xcbeautify || failed=1
    ;;
  settings-gram)
    # Distribution, so the optimizer produces the frame sizes that overflowed a
    # device's 1008 KiB main stack; project.yml gives simulator builds that stack.
    # DEBUG keeps the screenshot fixtures; testability lets the UI tests attach.
    # The test-run file uses __TESTROOT__ paths, so Build/Products is self-contained.
    # Never infer a pass from a cache hit or fall back to a different configuration.
    # A missing prerequisite fails the shard but still lets GramTests below run: they
    # need neither the iPad nor the Distribution products.
    settings_runs=(.build-dd-settings-stack/Build/Products/Herdr_*.xctestrun)
    if [ "${#settings_runs[@]}" -ne 1 ] || [ ! -f "${settings_runs[0]}" ]; then
      echo "::error::expected one optimized Settings .xctestrun in Build/Products"
      failed=1
    elif ! boot_simulator "$IPAD_UDID" TestReceipts/settings-device-stack-boot.log; then
      failed=1
    elif ! {
        xcrun simctl uninstall "$IPAD_UDID" com.jerryfane.herdr 2>/dev/null || true
        xcrun simctl uninstall "$IPAD_UDID" com.jerryfane.herdr.uitests.xctrunner 2>/dev/null || true
        install_app_under_test "$IPAD_UDID" TestReceipts/settings-device-stack-install.log \
          "$SETTINGS_APP_UNDER_TEST"
      }; then
      failed=1
    else
      "$TIMEOUT_BIN" --signal=INT 40m xcodebuild test-without-building -xctestrun "${settings_runs[0]}" \
          -destination "platform=iOS Simulator,id=$IPAD_UDID" \
          -parallel-testing-enabled NO \
          -test-timeouts-enabled YES \
          -default-test-execution-time-allowance 300 \
          -maximum-test-execution-time-allowance 600 \
          -resultBundlePath TestReceipts/settings-device-stack.xcresult \
          -only-testing:HerdrUITests/SettingsTests/testCompactSettingsSurviveResizeAndResume \
          2>&1 | tee TestReceipts/settings-device-stack.log | xcbeautify || failed=1
      # XCTest activation can restart a crashed app and still report a pass.
      # Without a readable export the guard cannot tell, so that fails the shard too.
      if ! xcrun xcresulttool export attachments \
          --path TestReceipts/settings-device-stack.xcresult \
          --output-path TestReceipts/settings-device-stack-crash-check >/dev/null; then
        echo "::error::could not export the Settings regression's attachments to check for crashes"
        failed=1
      else
        crashes=$(find TestReceipts/settings-device-stack-crash-check -name '*.ips')
        if [ -n "$crashes" ]; then
          echo "::error::Crashes attached to the Settings regression: $crashes"
          failed=1
        else
          echo "Settings device-stack regression: no crash reports attached"
        fi
      fi
    fi
    # Then GramTests on the iPhone with the Debug build. The iPad is shut down first: the
    # hosted runner has 7 GB, and a second booted simulator adds to the memory pressure
    # measured during launch stalls (herdrup#418). Budget: run 39608758941 (39 GramTests,
    # ~17% slower runner) spent 21.7 min in 36 finished cases and hit the old 25m with
    # two cases left; 35m leaves room for the suite to grow.
    xcrun simctl shutdown "$IPAD_UDID" >/dev/null 2>&1 || true
    ready_devices="${ready_devices/ $IPAD_UDID / }"
    run_suite iPhoneGram "$IPHONE_UDID" 35m -only-testing:HerdrUITests/GramTests || failed=1
    ;;
  focused)
    case "${ONLY_DEVICE:-iphone}" in
      ipad|ipad-pro-13) label=iPad; udid="$IPAD_UDID" ;;
      *)    label=iPhone; udid="$IPHONE_UDID" ;;
    esac
    if [[ "$ONLY_SUITE" = DesktopReferenceShots || "$ONLY_SUITE" = DesktopGramAndSettingsReferences || "$ONLY_SUITE" = DesktopGramReferenceShots || "$ONLY_SUITE" = DesktopSettingsReferenceShots || "$ONLY_SUITE" = DesktopDetailReferenceShots || "$ONLY_SUITE" = DesktopGramReferenceShots/* || "$ONLY_SUITE" = DesktopSettingsReferenceShots/* || "$ONLY_SUITE" = DesktopDetailReferenceShots/* ]]; then
      if [ "$label" != iPad ]; then
        echo "::error::desktop reference groups require only_device=ipad or ipad-pro-13"
        exit 1
      fi
      # Default to both references; a failed primary-device capture can be replaced alone.
      reference_classes=("${DESKTOP_REFERENCE_CLASSES[@]}")
      if [ "$ONLY_SUITE" = DesktopGramAndSettingsReferences ]; then
        reference_classes=(DesktopGramReferenceShots DesktopSettingsReferenceShots)
      elif [[ "$ONLY_SUITE" != DesktopReferenceShots ]]; then
        reference_classes=("$ONLY_SUITE")
      fi
      echo "::notice::focused dispatch: $ONLY_SUITE on ${ONLY_DEVICE:-ipad}"
      desktop_reference_round iPadDesktopReference "$IPAD_UDID" "${reference_classes[@]}" || failed=1
      xcrun simctl shutdown "$IPAD_UDID" >/dev/null 2>&1 || true
      # A shut-down device must be booted and checked again by any later round.
      ready_devices="${ready_devices/ $IPAD_UDID / }"
      if [ "${ONLY_DEVICE:-ipad}" != ipad-pro-13 ]; then
        desktop_reference_round iPad11DesktopReference "$IPAD11_UDID" "${reference_classes[@]}" || failed=1
      fi
    else
      # The iPad as the ipad shard prepares it: boot, then the screen recorder, then the
      # rounds. Focused iPad runs that went straight to the install (40822219713,
      # 40823615938) hung in `simctl install` for its whole 5m on Xcode 27; the ipad shard,
      # which starts the recorder first, installed the same build on the same device in
      # 17 s (40794761077). The video is also the receipt a focused iPad run lacked.
      if [ "$label" = iPad ]; then
        boot_simulator "$udid" TestReceipts/iPad-focused-recording-boot.log || exit 1
        xcrun simctl io "$udid" recordVideo TestReceipts/focused-iPad.mp4 \
          > TestReceipts/focused-iPad-video.log 2>&1 &
        recorder=$!
      fi
      echo "::notice::focused dispatch: HerdrUITests/$ONLY_SUITE on $label only"
      run_suite "$label-${ONLY_SUITE//\//-}" "$udid" 25m "-only-testing:HerdrUITests/$ONLY_SUITE" || failed=1
      stop_recording
    fi
    ;;
  *)
    echo "::error::unknown shard $shard"
    exit 1
    ;;
esac
exit "$failed"
