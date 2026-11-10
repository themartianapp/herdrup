#!/usr/bin/env bash
# Runs one simulator shard of the CI device suite. ci.yml runs the shards as
# parallel jobs; each job has already built the app and test bundles into .build-dd
# (build-for-testing) and exported IPHONE_UDID / IPAD_UDID.
#
#   iphone-terminal  TERMINAL_CLASSES, then ChatViewTests and PagingTests in rounds of
#                    their own, on iPhone
#   iphone-app       HerdrFontTests, then StatusMotionTests and the guest classes in rounds
#                    of their own, then every other HerdrUITests class on iPhone, then the
#                    SwiftTerm UIKit API tests on iPhone
#   ipad             iPad-specific rounds, then the SwiftTerm UIKit API tests on iPad
#   settings-build   optimized simulator build; CI caches its products before testing
#   settings-gram    iPad Settings resize/resume regression using that Distribution build
#                    with the device-sized stack (herdrup#416), even on cache hits; then
#                    GramTests on the iPhone with the Debug build
#   focused          ONLY_SUITE on ONLY_DEVICE (manual dispatch)
#   wait-runtimes    before the Metal toolchain download: wait until the simulator runtimes
#                    are Ready and mounted (wait_for_runtimes); needs no timeout binary yet
#
# The iPhone rounds are complementary BY CONSTRUCTION: iphone-terminal runs exactly
# TERMINAL_CLASSES plus ChatViewTests and PagingTests and settings-gram runs GramTests,
# while iphone-app skips those same identifiers, so a new test class lands in iphone-app
# without anyone listing it. A misspelled or renamed entry would silently drop that class, so
# iphone-terminal fails unless its result bundles show every listed class executed tests.
set -uo pipefail

shard="${1:?usage: ui-shard.sh iphone-terminal|iphone-app|ipad|settings-build|settings-gram|focused|wait-runtimes}"
TERMINAL_CLASSES=(TerminalControlTests TerminalResizeTests TerminalSearchTests TerminalSelectionTests TerminalDropTests)
SIM_STATE="$(cd "$(dirname "$0")" && pwd)/sim-state.py"
XCRESULT_TESTS="$(dirname "$SIM_STATE")/xcresult-tests.py"
mkdir -p TestReceipts
SIM_TMP=$(mktemp -d)

# wait-runtimes runs before Homebrew's coreutils is installed; bounded() falls back to a
# watchdog there. Every other shard needs the real timeout for its budgets.
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
if [ -z "$TIMEOUT_BIN" ] && [ "$shard" != wait-runtimes ]; then
  echo "::error::no timeout binary; per-suite budgets would be unenforceable"
  exit 1
fi

# bounded SECONDS COMMAND...: runs COMMAND, TERMs it after SECONDS (KILL 5 s later).
bounded() {
  local seconds="$1" pid watchdog status=0
  shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" --signal=TERM --kill-after=5s "${seconds}s" "$@"
    return
  fi
  "$@" &
  pid=$!
  ( sleep "$seconds"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) &
  watchdog=$!
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$status"
}

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
  local log="$1" udid="$2" start probe=0 device_status
  simulator_device_state=
  start=$(date +%s)
  while :; do
    probe=$((probe + 1))
    if "$TIMEOUT_BIN" --signal=TERM --kill-after=5s 30s xcrun simctl list devices --json >"$SIM_TMP/devices.json" 2>>"$log"; then
      echo "$(date -u +%FT%TZ) CoreSimulator answered after $(( $(date +%s) - start )) s ($probe probes)" | tee -a "$log"
      device_status=0
      simulator_device_state=$(python3 "$SIM_STATE" device "$SIM_TMP/devices.json" "$udid" 2>>"$log") || device_status=$?
      if [ "$device_status" -eq 3 ]; then
        simulator_device_state=Unavailable
        echo "::error::infrastructure: simulator $udid is unavailable, its runtime is gone (actions/runner-images#14946); see $log"
        return 1
      elif [ "$device_status" -ne 0 ]; then
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

# SIMULATOR RUNTIMES CAN BE UNMOUNTED MID-JOB ON THE XCODE 27 IMAGE (actions/runner-images#14946).
# When `xcodebuild -downloadComponent MetalToolchain` mounts its cryptex within milliseconds of
# simdiskimaged mounting an iOS runtime's, the runtime gets attached twice, and simdiskimaged
# later force-unmounts it: every booted simulator goes down, and every simctl or xcodebuild call
# on that runtime's devices fails until it is mounted again. ci.yml ran `xcodebuild -version`
# (which starts CoreSimulator) 3-5 s before that download. 13 hosted jobs from 2026-10-29 to
# 2026-11-07 lost their runtime and then failed every later round, e.g. 42335785645 (iphone-app:
# "The iOS 27.2 simulator runtime is not available. runtime path not found"), 42319983254 and
# 41841861442 (ipad: "Unable to boot device because we cannot determine the runtime bundle",
# "cannot determine current simulator state", and "Unable to find a device matching the
# provided destination specifier" for the SwiftTerm build). ci.yml now runs wait-runtimes before
# the download; boot_simulator checks each round's runtime, and recover_simulator mounts a lost
# one again.
runtime_verdict=
# check_device_runtime UDID LOG: 0 when the device's runtime is Ready and mounted and the device
# is available on it, 1 when simctl says otherwise, 2 when simctl did not answer (readiness then
# waits for the service as before).
check_device_runtime() {
  local udid="$1" log="$2" status=0 device_status=0
  runtime_verdict="simctl did not answer"
  if ! bounded 60 xcrun simctl runtime list -j >"$SIM_TMP/runtimes.json" 2>>"$log" \
      || ! bounded 60 xcrun simctl list devices --json >"$SIM_TMP/devices.json" 2>>"$log"; then
    echo "$(date -u +%FT%TZ) runtime check: simctl did not answer in 60 s" >>"$log"
    return 2
  fi
  python3 "$SIM_STATE" runtimes "$SIM_TMP/runtimes.json" "$SIM_TMP/devices.json" "$udid" \
    >"$SIM_TMP/runtime-verdict.txt" 2>&1 || status=1
  sed "s/^/$(date -u +%FT%TZ) runtime: /" "$SIM_TMP/runtime-verdict.txt" >>"$log"
  runtime_verdict=$(grep -v '(ignored)' "$SIM_TMP/runtime-verdict.txt" | paste -sd ';' -)
  # A mounted runtime that CoreSimulator has not matched the device to is lost all the same:
  # probe run 42766613734's device stayed "unavailable, runtime profile not found" after the
  # runtime was mounted again.
  python3 "$SIM_STATE" device "$SIM_TMP/devices.json" "$udid" >>"$log" 2>&1 || device_status=$?
  if [ "$device_status" -eq 3 ]; then
    status=1
    runtime_verdict="$runtime_verdict; $udid is unavailable"
  fi
  return "$status"
}
# wait_for_runtimes LOG BUDGET_SECONDS: waits until every simulator runtime that is not Unusable
# is Ready and mounted. Non-iOS runtimes that never get there only warn; this suite needs iOS.
wait_for_runtimes() {
  local log="$1" budget="$2" start probe=0 status
  start=$(date +%s)
  while :; do
    probe=$((probe + 1))
    status=1
    if bounded 60 xcrun simctl runtime list -j >"$SIM_TMP/runtimes.json" 2>>"$log"; then
      if [ "$probe" -eq 1 ]; then
        { echo "$(date -u +%FT%TZ) simctl runtime list -j:"; cat "$SIM_TMP/runtimes.json"; } >>"$log"
      fi
      status=0
      python3 "$SIM_STATE" runtimes "$SIM_TMP/runtimes.json" >"$SIM_TMP/runtime-verdict.txt" 2>&1 || status=$?
      sed "s/^/$(date -u +%FT%TZ) probe $probe: /" "$SIM_TMP/runtime-verdict.txt" >>"$log"
      runtime_verdict=$(grep -v '(ignored)' "$SIM_TMP/runtime-verdict.txt" | paste -sd ';' -)
      if [ "$status" -eq 0 ]; then
        echo "$(date -u +%FT%TZ) simulator runtimes Ready and mounted after $(( $(date +%s) - start )) s: $runtime_verdict" | tee -a "$log"
        return 0
      fi
    else
      echo "$(date -u +%FT%TZ) probe $probe: simctl runtime list did not answer in 60 s" >>"$log"
    fi
    if [ $(( $(date +%s) - start )) -ge "$budget" ]; then
      if [ "$status" -eq 2 ]; then
        echo "::warning::the iOS simulator runtimes are Ready and mounted, other runtimes are not after ${budget}s: $runtime_verdict; see $log"
        return 0
      fi
      echo "::error::infrastructure: the iOS simulator runtimes were not Ready and mounted within ${budget}s: ${runtime_verdict:-simctl did not answer}; see $log"
      return 1
    fi
    sleep 5
  done
}
# Mounts lost runtimes again and makes CoreSimulator see them. Measured on a hosted runner
# whose iOS runtime was force-unmounted on purpose (probe run 42766613734): restarting
# CoreSimulatorService alone left it unmounted for 120 s; restarting simdiskimaged (launchd
# relaunches it) mounted it again within 2 s, but the device stayed "unavailable, runtime
# profile not found" because CoreSimulatorService had already started without it. So:
# simdiskimaged first, then CoreSimulatorService once the runtimes are mounted, then wait for
# the device to be available. Every booted simulator goes down with the service.
remount_runtimes() {
  local log="$1" udid="$2" start
  echo "$(date -u +%FT%TZ) shutting down every simulator; restarting simdiskimaged" | tee -a "$log"
  bounded 120 xcrun simctl shutdown all >>"$log" 2>&1 || true
  ready_devices=" "
  sudo -n killall -9 simdiskimaged >>"$log" 2>&1 || true
  wait_for_runtimes "$log" 300 || return 1
  echo "$(date -u +%FT%TZ) restarting CoreSimulatorService so it finds the mounted runtimes" | tee -a "$log"
  killall -9 com.apple.CoreSimulator.CoreSimulatorService >>"$log" 2>&1 || true
  start=$(date +%s)
  while :; do
    if bounded 60 xcrun simctl list devices --json >"$SIM_TMP/devices.json" 2>>"$log" \
        && python3 "$SIM_STATE" device "$SIM_TMP/devices.json" "$udid" >>"$log" 2>&1; then
      echo "$(date -u +%FT%TZ) $udid is available again after $(( $(date +%s) - start )) s" | tee -a "$log"
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 180 ]; then
      echo "::error::infrastructure: $udid is still unavailable 180 s after its runtime was mounted again; see $log"
      return 1
    fi
    sleep 5
  done
}
# The unified log of runtime mounts and unmounts: the evidence of what took a runtime away.
save_runtime_log() {
  local out="$1" minutes="$2"
  bounded 180 log show --last "${minutes}m" --style compact \
    --predicate 'process == "simdiskimaged" OR (process == "CoreSimulatorService" AND (eventMessage CONTAINS[c] "unmount" OR eventMessage CONTAINS[c] "runtime"))' \
    >"$out" 2>&1 || true
}

boot_simulator() {
  local udid="$1" log="$2" status=0 budget=10m simulator_device_state= runtime_status=0
  echo "$(date -u +%FT%TZ) checking simulator readiness for $udid" >"$log"
  # Every round states its runtime's mount on stdout: the job log then shows whether the
  # runtime stayed mounted through the shard.
  check_device_runtime "$udid" "$log" || runtime_status=$?
  if [ "$runtime_status" -eq 1 ]; then
    ready_devices="${ready_devices/ $udid / }"
    echo "::error::infrastructure: the runtime of simulator $udid is not Ready and mounted: $runtime_verdict; see $log"
    return 1
  fi
  echo "$(date -u +%FT%TZ) runtime of $udid: $runtime_verdict"
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

# THE ONE INFRASTRUCTURE RECOVERY OF A ROUND. A round whose simulator could not be prepared
# (runtime, boot, readiness or install failed) or whose test runner died before any test case
# ran has no test result. It gets one recovery and one more attempt; a second infrastructure
# failure, and every failure of a test case that ran, stands. Hosted runs needed each step:
# a lost runtime (above) needs remounting; "Mach error -308 - (ipc/mig) server died" from
# `simctl install` (41524978734, 41402657305, after CoreSimulator was silent for 151-375 s)
# needs the device rebooted; a runner that crashed before its first test (41775711449) and a
# device xcodebuild could not find (41616977089) need both. A device that could not even be
# prepared is also erased, so the retry cold-boots a clean one.
recovered_rounds=" "
recover_simulator() {
  local udid="$1" label="$2" reason="$3" erase="$4" status=0 part
  local log="TestReceipts/$label-recovery.log"
  case "$recovered_rounds" in *" $label "*)
    echo "::error::infrastructure: $label: $reason, after the round's one recovery; see TestReceipts/$label-*"
    return 1
    ;;
  esac
  recovered_rounds="$recovered_rounds$label "
  stop_recording
  # xcodebuild refuses an existing -resultBundlePath, and the retry rewrites the boot and
  # install logs, so the first attempt's evidence moves aside first.
  for part in first.log first.xcresult boot.log install.log; do
    if [ -e "TestReceipts/$label-$part" ]; then
      mv "TestReceipts/$label-$part" "TestReceipts/$label-${part%%.*}-unstarted.${part#*.}"
    fi
  done
  echo "::warning::infrastructure, not a test result: $label: $reason. Recovering $udid and retrying the round once; the first attempt is TestReceipts/$label-*-unstarted.*, the recovery $log"
  echo "$(date -u +%FT%TZ) recovery of $label on $udid: $reason" >"$log"
  check_device_runtime "$udid" "$log" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "$(date -u +%FT%TZ) the runtime of $udid is not confirmed Ready and mounted: $runtime_verdict" | tee -a "$log"
    save_runtime_log "TestReceipts/$label-recovery-runtime-events.log" 60
    remount_runtimes "$log" "$udid" || return 1
  fi
  echo "$(date -u +%FT%TZ) simctl shutdown $udid" >>"$log"
  bounded 120 xcrun simctl shutdown "$udid" >>"$log" 2>&1 || true
  ready_devices="${ready_devices/ $udid / }"
  if [ "$erase" = erase ]; then
    echo "$(date -u +%FT%TZ) simctl erase $udid" | tee -a "$log"
    if bounded 180 xcrun simctl erase "$udid" >>"$log" 2>&1; then
      # An erased device boots cold again: it gets the cold-boot budget.
      cold_booted="${cold_booted/ $udid / }"
    else
      echo "$(date -u +%FT%TZ) erase failed; booting the device as it is" | tee -a "$log"
    fi
  fi
}

# Steps that need a booted device but install no app (screen recorders, the SwiftTerm package
# tests, the desktop references' device settings): boot, with the one recovery.
ensure_simulator() {
  local udid="$1" label="$2"
  boot_simulator "$udid" "TestReceipts/$label-boot.log" && return 0
  recover_simulator "$udid" "$label" "its simulator could not be booted (see the error above)" erase || return 1
  boot_simulator "$udid" "TestReceipts/$label-boot.log"
}

# prepare_round LABEL UDID APP [SETUP]: boots the device, runs SETUP UDID (device settings the
# round needs: desktop_reference_device_setup, settings_device_setup) and installs APP, with
# the round's one recovery when that fails. reprepare_round takes the same arguments and
# does it once, after a recovery rebooted or erased the device, so the settings hold again.
prepare_round() {
  local label="$1" udid="$2" app="$3" setup="${4:-}"
  reprepare_round "$label" "$udid" "$app" "$setup" && return 0
  recover_simulator "$udid" "$label" "its simulator could not be prepared (see the error above)" erase || return 1
  reprepare_round "$label" "$udid" "$app" "$setup"
}
reprepare_round() {
  local label="$1" udid="$2" app="$3" setup="${4:-}"
  boot_simulator "$udid" "TestReceipts/$label-boot.log" || return 1
  if [ -n "$setup" ] && ! "$setup" "$udid"; then
    echo "::error::$label: $setup failed on $udid"
    return 1
  fi
  install_app_under_test "$udid" "TestReceipts/$label-install.log" "$app"
}
# The optimized Settings regression starts from a fresh install of its Distribution app.
settings_device_setup() {
  xcrun simctl uninstall "$1" com.jerryfane.herdr 2>/dev/null || true
  xcrun simctl uninstall "$1" com.jerryfane.herdr.uitests.xctrunner 2>/dev/null || true
}

# Prints one -only-testing argument per failed Class/method test case in an .xcresult.
failed_tests() {
  xcrun xcresulttool get test-results tests --path "$1" 2>/dev/null | python3 "$XCRESULT_TESTS" failed-tests
}

# Succeeds only when a round executed no test case at all: its log has no XCTest result
# line and its result bundle records no Class/method test case. The runner-error pseudo
# case (see failed_tests) does not count as a test. A bundle that cannot be read counts
# as "tests may have run", so a round that ran a test is never treated as unstarted.
ran_no_test_case() {
  local log="$1" bundle="$2"
  if grep -qE "^Test Case '.*' (passed|failed|skipped) \(" "$log"; then
    return 1
  fi
  xcrun xcresulttool get test-results tests --path "$bundle" 2>/dev/null | python3 "$XCRESULT_TESTS" ran-none
}

# One xcodebuild invocation of a round into TestReceipts/$label-first.*.
# A WALL-CLOCK BOUND PER INVOCATION, so one wedged case cannot eat the job budget
# and take the receipt upload down with it. Per-case allowances make xcodebuild
# fail a stuck test with diagnostics instead of blocking to the deadline.
first_run() {
  local label="$1" udid="$2" budget="$3" status=0
  shift 3
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
  return "$status"
}

# What the last run_suite round came to, for check_classes_ran's message: passed, failed,
# timeout (its budget ran out) or unstarted (no test case could run).
last_round_result=
# run_suite [--setup FN] LABEL UDID BUDGET XCODEBUILD_ARGS...: one round of the Debug app.
# FN UDID applies device settings the round needs, before every install (prepare_round).
run_suite() {
  local setup=
  if [ "$1" = --setup ]; then
    setup="$2"
    shift 2
  fi
  local label="$1" udid="$2" budget="$3"
  shift 3
  local status=0 runner_error
  last_round_result=unstarted
  # Boot outside the test deadline. Booting during the build was measured to slow both.
  prepare_round "$label" "$udid" "$APP_UNDER_TEST" "$setup" || return 1
  first_run "$label" "$udid" "$budget" "$@" || status=$?
  # A round whose test runner died before any test started is a simulator failure, not a
  # test result. Run 41775711449 (iPhoneTerminal, Xcode 27): 199 s after launch, "Early
  # unexpected exit, operation never finished bootstrapping ... The test runner crashed
  # while preparing to run tests", zero test cases, and the whole PR's CI ran again. Such a
  # round gets the recovery (recover_simulator) and a fresh copy of its budget. The retry
  # used to get only what was left: on #628 run 41996536208 the crash took 4 min of
  # iPhoneChat's 10m, the retry got 429 s, ran 13 of 15 ChatViewTests and timed out. The
  # job deadline stays the ceiling on the total. A round in which any test case ran is
  # never retried, and a timeout is never retried (below).
  if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$status" -ne 130 ] \
      && ran_no_test_case "TestReceipts/$label-first.log" "TestReceipts/$label-first.xcresult"; then
    runner_error=$(grep -m1 -E 'encountered an error|Unable to find a device matching' "TestReceipts/$label-first.log" | sed 's/^[[:space:]]*//')
    recover_simulator "$udid" "$label" "executed no test case (xcodebuild exit $status): ${runner_error:-no runner error line in the log}" reboot || return 1
    status=0
    reprepare_round "$label" "$udid" "$APP_UNDER_TEST" "$setup" || return 1
    first_run "$label" "$udid" "$budget" "$@" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    last_round_result=passed
    return 0
  fi
  stop_recording
  if [ "$status" -eq 124 ] || [ "$status" -eq 130 ]; then
    last_round_result=timeout
    # A timeout is a failure on its own evidence; a rerun would spend the budget again.
    echo "::error::$label exceeded its ${budget} budget; see TestReceipts/$label-first.log"
    return 1
  fi
  last_round_result=failed
  local failed rerun
  failed=$(failed_tests "TestReceipts/$label-first.xcresult")
  if [ -n "$failed" ]; then
    rerun=0
    infra_rerun "$label" "$udid" "$failed" "$APP_UNDER_TEST" "$setup" || rerun=$?
    if [ "$rerun" -ne 2 ]; then
      [ "$rerun" -eq 0 ] && last_round_result=passed
      return "$rerun"
    fi
  fi
  echo "::error::$label first run failed; the failure stands. Rerunning only the failed tests for raw diagnostics"
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

# A ROUND WHOSE EVERY FAILURE IS THE SIMULATOR'S. When every failure message of every failed
# case is an infrastructure signature (xcresult-tests.py INFRASTRUCTURE: a simulator system
# process crashed, the app never got a process, XCTest could not terminate it) and the app
# left no crash report, only those cases run once more on a rebooted device, and their result
# is the round's. That uses the round's one recovery (recover_simulator). Any other failure
# message, an assertion above all, keeps the whole round failed with no rerun of its result.
# Run 42770272602's iPad shard failed iPadResize on "Critical process SpringBoard crashed"
# (SpringBoard SIGBUS in NSXPCEncoder) and its follow-on "pid 0", and iPadGramColumn on an
# app.launch() that got no process in 153 s; the diagnostic reruns of all three passed.
# infra_rerun LABEL UDID FAILED APP [SETUP]: APP and SETUP as for prepare_round.
# Returns 0 when the rerun passed, 1 when it ran and failed, 2 when the round does not qualify.
infra_rerun() {
  local label="$1" udid="$2" failed="$3" app="$4" setup="${5:-}" status=0 bundle_id part
  local kinds="TestReceipts/$label-failure-kinds.txt"
  xcrun xcresulttool get test-results tests --path "TestReceipts/$label-first.xcresult" 2>/dev/null \
    | python3 "$XCRESULT_TESTS" infra-only >"$kinds" 2>&1 || return 2
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist") || return 2
  # Without the attachments there is no proof the app did not crash: no rerun then.
  xcrun xcresulttool export attachments --path "TestReceipts/$label-first.xcresult" \
    --output-path "$SIM_TMP/$label-attachments" >/dev/null 2>&1 || return 2
  if python3 "$XCRESULT_TESTS" app-crashed "$SIM_TMP/$label-attachments" "$bundle_id" >>"$kinds"; then
    return 2
  fi
  case "$recovered_rounds" in *" $label "*) return 2 ;; esac
  recovered_rounds="$recovered_rounds$label "
  echo "::warning::infrastructure, not a test result: every failure of $label is the simulator's ($(paste -sd ';' "$kinds")). Rebooting $udid and running only those cases again once; their result stands. The first run is TestReceipts/$label-first.*, the rerun TestReceipts/$label-infra-rerun.*"
  bounded 120 xcrun simctl shutdown "$udid" >"TestReceipts/$label-infra-shutdown.log" 2>&1 || true
  ready_devices="${ready_devices/ $udid / }"
  for part in boot.log install.log; do
    mv "TestReceipts/$label-$part" "TestReceipts/$label-${part%%.*}-before-infra-rerun.${part#*.}" 2>/dev/null || true
  done
  reprepare_round "$label" "$udid" "$app" "$setup" || return 1
  # shellcheck disable=SC2086 # one -only-testing argument per line
  "$TIMEOUT_BIN" --signal=INT 15m xcodebuild test-without-building "${PROJECT[@]}" \
      -destination "platform=iOS Simulator,id=$udid" \
      -parallel-testing-enabled NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 300 \
      -maximum-test-execution-time-allowance 600 \
      -resultBundlePath "TestReceipts/$label-infra-rerun.xcresult" \
      $failed 2>&1 | tee "TestReceipts/$label-infra-rerun.log" | xcbeautify || status=$?
  if [ "$status" -eq 0 ]; then
    echo "$label: the rerun of its infrastructure failures passed"
    return 0
  fi
  echo "::error::$label failed, and the rerun of its infrastructure failures failed too (xcodebuild exit $status); the failure stands; see TestReceipts/$label-infra-rerun.log"
  return 1
}

# Fails unless every class named after the bundle executed at least one test in it. Only a
# round that ran tests and still skipped a listed class shows a stale name; a round that never
# started, or ran out of its budget, says so instead. Before this distinction, every round
# lost to the simulator (41775711449, 41616977089, 41619260120) or to its budget (40754394287)
# also reported its classes as "no longer matches a class", although all of them existed.
check_classes_ran() {
  local bundle="$1"
  shift
  xcrun xcresulttool get test-results tests --path "$bundle" 2>/dev/null |
    python3 "$XCRESULT_TESTS" check-classes "$bundle" "${last_round_result:-unknown}" "$@"
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
# The desktop references' device settings. Each class's round applies them before its
# install (run_suite --setup), so they hold even after a recovery rebooted or erased the device.
desktop_reference_device_setup() {
  xcrun simctl ui "$1" appearance dark || return 1
  xcrun simctl status_bar "$1" override "${DESKTOP_REFERENCE_STATUS_BAR[@]}" || return 1
}
desktop_reference_round() {
  local label="$1" udid="$2" bundle_id class round budget status=0
  shift 2
  local classes=("${DESKTOP_REFERENCE_CLASSES[@]}")
  if [ "$#" -gt 0 ]; then classes=("$@"); fi
  ensure_simulator "$udid" "$label" || return 1
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_UNDER_TEST/Info.plist") || return 1
  xcrun simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
  desktop_reference_device_setup "$udid" || return 1
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
    # 20m for the Gram references (p95 11.9 min, slowest pass 12.4 min over 306 passes on
    # both iPads), 15m for the others (p95 at most 9.9 min, slowest 11.3).
    case "$class" in
      DesktopGramReferenceShots*) budget=20m ;;
      *) budget=15m ;;
    esac
    run_suite --setup desktop_reference_device_setup "$round" "$udid" "$budget" \
      "-only-testing:HerdrUITests/$class" || status=1
    check_classes_ran "TestReceipts/$round-first.xcresult" "${class%%/*}" || status=1
  done
  stop_recording
  xcrun simctl status_bar "$udid" clear || true
  xcrun simctl ui "$udid" appearance light || true
  return "$status"
}

swiftterm_api() {
  local device="$1" udid="$2" label="SwiftTermUIKit-$1"
  # The build resolves its destination by UDID, so it needs the device's runtime: "SwiftTerm
  # test build failed" in 41841861442 and 42319983254 was "Unable to find a device matching
  # the provided destination specifier" after the runtime was unmounted. Boot (with the one
  # recovery) first; no install_app_under_test: these are package unit tests, and no
  # XCUIApplication launches an app, so the cold-boot install race (#418) does not apply.
  ensure_simulator "$udid" "$label" || return 1
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
# ROUND BUDGETS, FROM MEASURED DURATIONS. Each round's budget is the larger of 1.3 x the p95
# and the slowest pass + 2 min, rounded up to 5 min, over the passing first runs of hosted CI
# jobs created 2026-10-31..2026-11-10 (Xcode 27.1 image; duration = install done to result
# bundle written, so it includes xcodebuild's start-up). Measured with
# fleet-tools/state/herdrup-ci-flakes-20261110; "pass" means the round neither failed nor ran
# out. In that window 54 rounds ran out of their budget, e.g. iPadChatUX 16 times at 20m,
# iPadResize 5 times at 25m and iPhoneChat 5 times at 10m. A round that hangs
# still fails: the 300 s per-test allowance fails the stuck case either way.
case "$shard" in
  iphone-terminal)
    only=()
    for class in "${TERMINAL_CLASSES[@]}"; do only+=("-only-testing:HerdrUITests/$class"); done
    # 50m: p95 36.4 min, slowest pass 37.9 (n=138). 40m cut 42273527812 (one case hung for
    # its 300 s allowance, then the runner restarted) and 42200270228 short.
    run_suite iPhoneTerminal "$IPHONE_UDID" 50m "${only[@]}" || failed=1
    check_classes_ran TestReceipts/iPhoneTerminal-first.xcresult "${TERMINAL_CLASSES[@]}" || failed=1
    # GramTests run in settings-gram: after #445 this shard had ~40 min of tests against
    # ~26 (iphone-app) and ~24 (ipad), and settings-stack finished in ~13 min (runs
    # 39128731625, 39132955146, 39137628334).
    # ChatViewTests (#485, ~3.5 min on a hosted runner) run here: in the app round they
    # pushed iPhoneApp to 29 min of tests against its 30 m budget, which run 39930335960
    # exceeded. This shard had ~18 min of tests in that run against 40 m.
    # 15m: p95 9.5 min, slowest pass 9.8 (n=20 since ChatViewTests grew on 2026-11-06);
    # 10m cut 42632930170, 41996536208, 41402657305 and 41209406682 short.
    run_suite iPhoneChat "$IPHONE_UDID" 15m -only-testing:HerdrUITests/ChatViewTests || failed=1
    check_classes_ran TestReceipts/iPhoneChat-first.xcresult ChatViewTests || failed=1
    # Chat UX owns a separate round so its keyboard/history checks cannot consume
    # the general app suite's deadline. 25m: p95 15.8 min, slowest pass 17.4 (n=142).
    run_suite iPhoneChatUX "$IPHONE_UDID" 25m -only-testing:HerdrUITests/ChatUXSmokeTests || failed=1
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
    # StatusMotionTests photograph shapes over time and wait out tab switches: with them in
    # the app round, #433's run 38703928881 ran out of its 30 m on the last class.
    # 15m: p95 7.3 min, slowest pass 8.4 (n=150).
    run_suite iPhoneStatusMotion "$IPHONE_UDID" 15m -only-testing:HerdrUITests/StatusMotionTests || failed=1
    # 15m: p95 7.7 min, slowest pass 9.0 (n=144); 10m cut 42599598427 and 41332029469 short.
    run_suite iPhoneAgentFolders "$IPHONE_UDID" 15m -only-testing:HerdrUITests/AgentFoldersTests || failed=1
    check_classes_ran TestReceipts/iPhoneAgentFolders-first.xcresult AgentFoldersTests || failed=1
    run_suite iPhoneNeedsYouPill "$IPHONE_UDID" 10m -only-testing:HerdrUITests/NeedsYouPillTests || failed=1
    check_classes_ran TestReceipts/iPhoneNeedsYouPill-first.xcresult NeedsYouPillTests || failed=1
    # Update-card scenarios: keeping them in iPhoneApp repeatedly exhausted its cap before
    # the last classes. 15m: p95 6.3 min, slowest pass 8.3 (n=153).
    run_suite iPhoneServerUpdate "$IPHONE_UDID" 15m -only-testing:HerdrUITests/ServerUpdateUITests || failed=1
    check_classes_ran TestReceipts/iPhoneServerUpdate-first.xcresult ServerUpdateUITests || failed=1
    # The guest classes (#312) took ~18 min of the app round in run 42599598427, which with
    # two new GuestShellTests cases exceeded its 40m twice. 30m: only 3 passes on their own
    # round yet, all 21.0 min; 1.3 x that.
    GUEST_CLASSES=(GuestPaneTests GuestGramPaneTests GuestPushTests GuestShareTests GuestShellTests)
    guest=()
    for class in "${GUEST_CLASSES[@]}"; do guest+=("-only-testing:HerdrUITests/$class"); done
    run_suite iPhoneGuest "$IPHONE_UDID" 30m "${guest[@]}" || failed=1
    check_classes_ran TestReceipts/iPhoneGuest-first.xcresult "${GUEST_CLASSES[@]}" || failed=1
    skip=(-skip-testing:HerdrUITests/GramTests -skip-testing:HerdrUITests/StatusMotionTests
      -skip-testing:HerdrUITests/ChatViewTests -skip-testing:HerdrUITests/ChatUXSmokeTests -skip-testing:HerdrUITests/PagingTests
      -skip-testing:HerdrUITests/AgentFoldersTests -skip-testing:HerdrUITests/NeedsYouPillTests
      -skip-testing:HerdrUITests/ServerUpdateUITests)
    for class in "${GUEST_CLASSES[@]}"; do skip+=("-skip-testing:HerdrUITests/$class"); done
    for class in "${DESKTOP_REFERENCE_CLASSES[@]}"; do skip+=("-skip-testing:HerdrUITests/$class"); done
    for class in "${TERMINAL_CLASSES[@]}"; do skip+=("-skip-testing:HerdrUITests/$class"); done
    # 40m: p95 37.5 min, slowest pass 39.6 (n=136) while the guest classes ran here; without
    # them (their case times subtracted) p95 22.1, slowest 22.9, so 40m keeps that margin.
    run_suite iPhoneApp "$IPHONE_UDID" 40m -only-testing:HerdrUITests "${skip[@]}" || failed=1
    swiftterm_api iPhone "$IPHONE_UDID" || failed=1
    # Herdrup Desktop's 11-inch references; the 13-inch ones run in the ipad shard. This
    # shard had the most room (31 min against the ipad shard's 60 in run 40655871305).
    xcrun simctl shutdown "$IPHONE_UDID" >/dev/null 2>&1 || true
    desktop_reference_round iPad11DesktopReference "$IPAD11_UDID" || failed=1
    ;;
  ipad)
    ensure_simulator "$IPAD_UDID" iPadRecording || exit 1
    # Parallel test clones are disabled, so the video records the tested device.
    xcrun simctl io "$IPAD_UDID" recordVideo TestReceipts/terminal-resize-iPad.mp4 \
      > TestReceipts/terminal-resize-iPad-video.log 2>&1 &
    recorder=$!
    # 35m: p95 23.9 min, slowest pass 24.7 (n=130); 25m cut 5 runs short (42599598427,
    # 42376372751, 42319983254, 41370868124, 41352170375).
    run_suite iPadResize "$IPAD_UDID" 35m \
      -only-testing:HerdrUITests/TerminalResizeTests \
      -only-testing:HerdrUITests/DuoTransitionTests || failed=1
    stop_recording
    if [ ! -s TestReceipts/terminal-resize-iPad.mp4 ]; then
      echo "::warning::iPad video unavailable; consult recording log and xcresult screenshots"
    fi
    # The iPhone shards keep their coordinate/keyboard receipts; these rounds cover
    # iPad's hardware-keyboard prerequisite and the iPad-only detail column.
    # 25m: p95 17.3 min, slowest pass 19.5 (n=144); 20m cut 5 runs short (42632930170,
    # 41860358507, 41432817977, 41275806275, ...). Individual test limits are unchanged.
    run_suite iPadControl "$IPAD_UDID" 25m -only-testing:HerdrUITests/TerminalControlTests || failed=1
    run_suite iPadSelectAgent "$IPAD_UDID" 5m -only-testing:HerdrUITests/SelectAgentFieldTests || failed=1
    # Files dropped on the terminal attach to the composer (#575): iPad and Mac are where
    # a file is dragged in from Files or Finder.
    run_suite iPadTerminalDrop "$IPAD_UDID" 5m -only-testing:HerdrUITests/TerminalDropTests || failed=1
    # The needs-you pill pinned at the top of the sidebar (#551). 10m: p95 3.3 min, slowest
    # pass 3.8 (n=151).
    run_suite iPadNeedsYouPill "$IPAD_UDID" 10m -only-testing:HerdrUITests/NeedsYouPillTests || failed=1
    # Agent folders in the sidebar (#552): a closed folder's counts, open in place, kept open.
    run_suite iPadAgentFolders "$IPAD_UDID" 5m \
      -only-testing:HerdrUITests/AgentFoldersTests/testClosedFolderShowsWaitingCountAndOpensOnTap || failed=1
    # 30m: p95 19.9 min, slowest pass 20.6 (n=133); the old 20m cut 16 runs short, e.g.
    # 41169998628, 41177678247, 41402649405, 41402663682 and 41801268261.
    run_suite iPadChatUX "$IPAD_UDID" 30m -only-testing:HerdrUITests/ChatUXSmokeTests || failed=1
    check_classes_ran TestReceipts/iPadChatUX-first.xcresult ChatUXSmokeTests || failed=1
    # Gram's column width (#541): handles, drag, snap, reset and relaunch on the iPad. The
    # iPhone half (no handles) runs in the iPhone app round.
    run_suite iPadGramColumn "$IPAD_UDID" 10m -only-testing:HerdrUITests/GramColumnTests || failed=1
    check_classes_ran TestReceipts/iPadGramColumn-first.xcresult GramColumnTests || failed=1
    # The Chat's corner up arrow over the column's right resize band (#638 review F1): a tap
    # on the arrow must jump. The rest of ChatViewTests runs on the iPhone.
    run_suite iPadChatUpArrow "$IPAD_UDID" 5m \
      -only-testing:HerdrUITests/ChatViewTests/testUpArrowOverTheIPadColumnEdgeStillJumps || failed=1
    check_classes_ran TestReceipts/iPadChatUpArrow-first.xcresult ChatViewTests || failed=1
    # The GitHub star bar in the 320 pt sidebar (#602): compact layout, title on one line.
    run_suite iPadStarPrompt "$IPAD_UDID" 10m \
      -only-testing:HerdrUITests/GitHubStarPromptTests/testBarFitsTheIPadSidebar || failed=1
    check_classes_ran TestReceipts/iPadStarPrompt-first.xcresult GitHubStarPromptTests || failed=1
    # Herdrup Desktop's 13-inch references, before AgentListChrome leaves a window behind.
    desktop_reference_round iPadDesktopReference "$IPAD_UDID" || failed=1
    # Last of the app rounds: AgentListChromeTests shrinks the app into a window on purpose,
    # and iPadOS keeps that window for later launches, even across a reinstall. Run
    # 40537708095 (and 40552658219, which uninstalled the app after this round) ran
    # NeedsYouPill and the first ChatUX cases in a 715-722 pt window: no room for the chat
    # column and pixel probes off the window, failing four ChatUX cases that pass full screen.
    # 10m: p95 2.9 min, slowest pass 4.2 (n=151).
    run_suite iPadAgentListChrome "$IPAD_UDID" 10m -only-testing:HerdrUITests/AgentListChromeTests || failed=1
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
    elif ! prepare_round settings-device-stack "$IPAD_UDID" "$SETTINGS_APP_UNDER_TEST" settings_device_setup; then
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
    # measured during launch stalls (herdrup#418). 45m: p95 33.3 min, slowest pass 34.8
    # (n=151); 35m cut 41841861442, 41642629325 and 41523127667 short.
    xcrun simctl shutdown "$IPAD_UDID" >/dev/null 2>&1 || true
    ready_devices="${ready_devices/ $IPAD_UDID / }"
    run_suite iPhoneGram "$IPHONE_UDID" 45m -only-testing:HerdrUITests/GramTests || failed=1
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
        ensure_simulator "$udid" iPad-focused-recording || exit 1
        xcrun simctl io "$udid" recordVideo TestReceipts/focused-iPad.mp4 \
          > TestReceipts/focused-iPad-video.log 2>&1 &
        recorder=$!
      fi
      echo "::notice::focused dispatch: HerdrUITests/$ONLY_SUITE on $label only"
      run_suite "$label-${ONLY_SUITE//\//-}" "$udid" 25m "-only-testing:HerdrUITests/$ONLY_SUITE" || failed=1
      stop_recording
    fi
    ;;
  wait-runtimes)
    # 600 s: the runtimes were already mounted when the first call returned in the jobs
    # actions/runner-images#14946 measured (2-6 s); the bound only keeps a wedged
    # CoreSimulator from holding the job.
    wait_for_runtimes TestReceipts/wait-runtimes.log 600 || failed=1
    ;;
  *)
    echo "::error::unknown shard $shard"
    exit 1
    ;;
esac
exit "$failed"
