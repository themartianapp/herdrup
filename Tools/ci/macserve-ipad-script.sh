#!/usr/bin/env bash
# The macserve script shard `ipad-script-ondemand` (.macserve.json; template
# org-ios-sim-script-v1, run on request through macserve's API, not as a PR check; see
# docs/DESIGN.md, CI): Tools/ci/ui-shard.sh ipad-script-ondemand,
# the device rounds macserve's UI-test template cannot run as plain -only-testing selectors:
#   - Herdrup Desktop's references on the 13-inch and the 1180x820 pt iPad, which need the
#     simulator in dark appearance with a pinned status bar (simctl, before each round);
#   - AgentListChromeTests on the iPad after every full-screen round: it leaves the app in a
#     window, and iPadOS keeps that window for later launches;
#   - the iPad Settings resize/resume regression on an optimized Distribution build with the
#     device-sized 1008 KiB main stack (herdrup#416), with its attached-crash check;
#   - the vendored SwiftTerm's UIKit API tests (its own package scheme) on iPad and iPhone;
#   - before those, the built Herdr.app's version against project.yml's MARKETING_VERSION.
#
# The template has built the Debug app for its iPhone 18 Pro (MACSERVE_SIMULATOR_ID) into the
# derived data above MACSERVE_APP_DIR. ui-shard.sh builds into .build-dd and resolves packages
# into SourcePackages, so both link to that derived data, and build-for-testing adds only the
# test bundles. The iPads are this script's own simulators, as duo-column.sh creates its
# iPhone Duo; they are deleted on exit. TestReceipts is copied to MACSERVE_OUTPUT, the
# directory the job exports.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
: "${MACSERVE_SIMULATOR_ID:?run by the macserve script template, which sets MACSERVE_SIMULATOR_ID}"
: "${MACSERVE_APP_DIR:?run by the macserve script template, which sets MACSERVE_APP_DIR}"
: "${MACSERVE_OUTPUT:?run by the macserve script template, which sets MACSERVE_OUTPUT}"

TYPES=com.apple.CoreSimulator.SimDeviceType
RUNTIMES=(com.apple.CoreSimulator.SimRuntime.iOS-27-0 com.apple.CoreSimulator.SimRuntime.iOS-27-1)
DERIVED_DATA=$(cd "$MACSERVE_APP_DIR/../../.." && pwd) || exit 1
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || echo Tools/ci/timeout.py)
mkdir -p TestReceipts "$MACSERVE_OUTPUT"

created=()
finish() {
  local udid
  for udid in "${created[@]}"; do
    "$TIMEOUT_BIN" 120 xcrun simctl shutdown "$udid" >/dev/null 2>&1
    "$TIMEOUT_BIN" 120 xcrun simctl delete "$udid" >/dev/null 2>&1
  done
  cp -R TestReceipts "$MACSERVE_OUTPUT/" || true
}
trap finish EXIT

# create NAME DEVICE_TYPE...: the first device type that some runtime in RUNTIMES (the iPhone's
# iOS 27.0 first) accepts; prints its UDID. Only the listed types: never a substitute size.
create() {
  local name="$1" type runtime udid
  shift
  for type in "$@"; do
    for runtime in "${RUNTIMES[@]}"; do
      if udid=$(xcrun simctl create "$name-${MACSERVE_JOB_ID:-local}" "$TYPES.$type" "$runtime" 2>/dev/null); then
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
# Herdrup Desktop's second reference size is 1180x820 pt at @2x: the iPad Air 11-inch or the
# base iPad (A16); the iPad Pro 11-inch is not (1210x834).
IPAD11_UDID=$(create ipad11 iPad-Air-11-inch-M4 iPad-Air-11-inch-M3 iPad-Air-11-inch-M2 iPad-A16) || exit 1
created+=("$IPAD11_UDID")
export IPHONE_UDID="$MACSERVE_SIMULATOR_ID" IPAD_UDID IPAD11_UDID

mkdir -p "$DERIVED_DATA/SourcePackages" || exit 1
ln -sfn "$DERIVED_DATA" .build-dd || exit 1
ln -sfn "$DERIVED_DATA/SourcePackages" SourcePackages || exit 1
if ! "$TIMEOUT_BIN" --signal=INT --kill-after=15s 30m \
    xcodebuild build-for-testing -project Herdr.xcodeproj -scheme Herdr \
      -destination "platform=iOS Simulator,id=$IPAD_UDID" \
      -derivedDataPath .build-dd -clonedSourcePackagesDirPath SourcePackages \
      CODE_SIGNING_ALLOWED=NO >TestReceipts/debug-build-for-testing.log 2>&1; then
  echo "::error::Debug build-for-testing failed; see TestReceipts/debug-build-for-testing.log"
  tail -40 TestReceipts/debug-build-for-testing.log
  exit 1
fi

# THE BUILT BUNDLE VERSION, read from the built product, not the generated source plist:
# xcodegen writes the literal "$(MARKETING_VERSION)" into App/Info.plist and Xcode
# substitutes it during the build. Nothing set CFBundleShortVersionString for months, so
# xcodegen's default "1.0" shipped while project.yml said 0.1, and it surfaced only when
# Apple closed the 1.0 train (altool 90186). build-for-testing also produces a runner .app,
# whose version is unrelated, so this reads Herdr.app.
failed=0
APP=.build-dd/Build/Products/Debug-iphonesimulator/Herdr.app
BUILT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null)
EXPECTED=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*MARKETING_VERSION:[[:space:]]*//' | tr -d '" ')
echo "built CFBundleShortVersionString=${BUILT:-<none>}  project.yml MARKETING_VERSION=$EXPECTED"
if [ -z "$BUILT" ] || [ "$BUILT" != "$EXPECTED" ]; then
  echo "::error::built version (${BUILT:-none}) does not match project.yml MARKETING_VERSION ($EXPECTED)"
  failed=1
fi

Tools/ci/ui-shard.sh ipad-script-ondemand || failed=1
exit "$failed"
