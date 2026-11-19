#!/usr/bin/env bash
# The macserve script shards `desktop-refs` and `settings-stack` (.macserve.json; template
# org-ios-sim-script-v1, PR checks mac-evidence/org-ios-sim-script-v1/<shard>):
# Tools/ci/ui-shard.sh SHARD, the device rounds macserve's UI-test template cannot run as
# plain -only-testing selectors. The template runs a shard's file with no arguments, so
# Tools/ci/macserve-desktop-refs.sh and Tools/ci/macserve-settings-stack.sh run this one
# with their shard.
#   desktop-refs:
#   - Herdrup Desktop's references on the 13-inch and the 1180x820 pt iPad, which need the
#     simulator in dark appearance with a pinned status bar (simctl, before each round).
#   settings-stack:
#   - the iPad Settings resize/resume regression on an optimized Distribution build with the
#     device-sized 1008 KiB main stack (herdrup#416), with its attached-crash check. The
#     UI-test template builds only the scheme's Debug configuration.
# These were the `ipad-script` shard with three more pieces, which run in parallel jobs now:
# AgentListChromeTests in the `ipad` UI-test shard (it returns the app to full screen), the
# SwiftTerm UIKit API tests in the unit_test shards swiftterm-ipad and swiftterm-iphone, and
# the built-version check as Tools/ci/test_project_version.py in CI's Linux job.
#
# The template has built the Debug app for its iPhone 18 Pro (MACSERVE_SIMULATOR_ID) into the
# derived data above MACSERVE_APP_DIR. ui-shard.sh builds into .build-dd and resolves packages
# into SourcePackages, so both link to that derived data. desktop-refs adds the UI-test
# bundle for the iPad there (build-for-testing); settings-stack builds its own Distribution
# products. The iPads are this script's own simulators, only those its shard uses, as
# duo-column.sh creates its iPhone Duo; they are deleted on exit. TestReceipts, with
# FLAKES.txt when a failed test passed on its retry, is copied to MACSERVE_OUTPUT, the
# directory the job exports. The exit status is ui-shard.sh's (a round whose failed tests
# all passed their one retry passes) or a failed step here.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
: "${MACSERVE_SIMULATOR_ID:?run by the macserve script template, which sets MACSERVE_SIMULATOR_ID}"
: "${MACSERVE_APP_DIR:?run by the macserve script template, which sets MACSERVE_APP_DIR}"
: "${MACSERVE_OUTPUT:?run by the macserve script template, which sets MACSERVE_OUTPUT}"
shard="${1:-}"
case "$shard" in
  desktop-refs|settings-stack) ;;
  *)
    echo "::error::usage: macserve-script-shard.sh desktop-refs|settings-stack, not '$shard'" >&2
    exit 64
    ;;
esac

TYPES=com.apple.CoreSimulator.SimDeviceType
RUNTIMES=(com.apple.CoreSimulator.SimRuntime.iOS-27-0 com.apple.CoreSimulator.SimRuntime.iOS-27-1)
DERIVED_DATA=$(cd "$MACSERVE_APP_DIR/../../.." && pwd) || exit 1
# shellcheck source=Tools/ci/timeout-bin.sh
. Tools/ci/timeout-bin.sh
mkdir -p TestReceipts "$MACSERVE_OUTPUT"

created=()
finish() {
  local udid
  # Receipts first: the simulator clean-up below can take minutes on a wedged CoreSimulator.
  cp -R TestReceipts "$MACSERVE_OUTPUT/" || true
  for udid in "${created[@]}"; do
    "$TIMEOUT_BIN" --signal=TERM --kill-after=15s 120 xcrun simctl shutdown "$udid" >/dev/null 2>&1
    "$TIMEOUT_BIN" --signal=TERM --kill-after=15s 120 xcrun simctl delete "$udid" >/dev/null 2>&1
  done
}
trap finish EXIT

# create NAME DEVICE_TYPE...: the first device type that some runtime in RUNTIMES (the iPhone's
# iOS 27.0 first) accepts; prints its UDID. Only the listed types: never a substitute size.
create() {
  local name="$1" type runtime udid
  shift
  for type in "$@"; do
    for runtime in "${RUNTIMES[@]}"; do
      if udid=$("$TIMEOUT_BIN" --signal=TERM --kill-after=15s 120 xcrun simctl create "$name-${MACSERVE_JOB_ID:-local}" "$TYPES.$type" "$runtime" 2>/dev/null); then
        echo "$name: $udid ($type, $runtime)" >&2
        echo "$udid"
        return 0
      fi
    done
  done
  echo "::error::no runtime in ${RUNTIMES[*]} accepts any of $*" >&2
  return 1
}
IPAD_UDID=$(create ipad iPad-Pro-13-inch-M5-12GB) || exit 1
created+=("$IPAD_UDID")
export IPHONE_UDID="$MACSERVE_SIMULATOR_ID" IPAD_UDID
if [ "$shard" = desktop-refs ]; then
  # Herdrup Desktop's second reference size is 1180x820 pt at @2x: the iPad Air 11-inch or the
  # base iPad (A16); the iPad Pro 11-inch is not (1210x834).
  IPAD11_UDID=$(create ipad11 iPad-Air-11-inch-M4 iPad-Air-11-inch-M3 iPad-Air-11-inch-M2 iPad-A16) || exit 1
  created+=("$IPAD11_UDID")
  export IPAD11_UDID
fi

mkdir -p "$DERIVED_DATA/SourcePackages" || exit 1
ln -sfn "$DERIVED_DATA" .build-dd || exit 1
ln -sfn "$DERIVED_DATA/SourcePackages" SourcePackages || exit 1
# Only the references' UI-test bundle: the scheme's test action also holds HerdrFontTests and
# SwiftTerm's tests, which no round here runs.
if [ "$shard" = desktop-refs ] && ! "$TIMEOUT_BIN" --signal=INT --kill-after=15s 30m \
    xcodebuild build-for-testing -project Herdr.xcodeproj -scheme Herdr \
      -destination "platform=iOS Simulator,id=$IPAD_UDID" \
      -derivedDataPath .build-dd -clonedSourcePackagesDirPath SourcePackages \
      -only-testing:HerdrUITests \
      CODE_SIGNING_ALLOWED=NO >TestReceipts/debug-build-for-testing.log 2>&1; then
  echo "::error::Debug build-for-testing failed; see TestReceipts/debug-build-for-testing.log"
  tail -40 TestReceipts/debug-build-for-testing.log
  exit 1
fi

# THE WHOLE SHARD IS BOUNDED BELOW macserve's 2 h JOB CAP, so a hang the rounds' own bounds
# miss still leaves time to copy TestReceipts to MACSERVE_OUTPUT (finish): herdrup #674's
# ipad-script job j_1b3bd71b hung in an unbounded simctl call until macserve killed it at
# the cap, and exported nothing. The build above takes at most 30 min of the 2 h.
"$TIMEOUT_BIN" --signal=TERM --kill-after=60s 80m Tools/ci/ui-shard.sh "$shard"
status=$?
if [ "$status" -eq 124 ]; then
  echo "::error::Tools/ci/ui-shard.sh $shard ran past its 80m bound; see TestReceipts"
fi
exit "$status"
