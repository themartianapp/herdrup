#!/usr/bin/env bash
# One-off build-for-testing facts for macserve's build-once design (DESIGN-build-once-and-tiers
# §3.1 item 1). Run as the macserve script shard `bft-facts` (.macserve.json; /bin/bash, cwd
# work_dir, env MACSERVE_SIMULATOR_ID, MACSERVE_APP_DIR, MACSERVE_OUTPUT, MACSERVE_JOB_ID) or
# by hand on a Mac. It runs xcodegen, then ONE generic build-for-testing:
#   xcodebuild -project Herdr.xcodeproj -scheme Herdr -configuration Debug -sdk iphonesimulator
#     -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO
#     build-for-testing
# into a fresh local derived data (.bft-dd), and prints:
#   (a) the size of Build/Products, in total and per top-level entry;
#   (b) every .xctestrun under Products and their count (must be 1), with the test targets
#       each holds (must include HerdrUITests and HerdrFontTests);
#   (c) every symlink under Products and their count (must be 0);
#   (d) one short UI test run with test-without-building -xctestrun from that one build on an
#       iPhone 18 Pro and on an iPad simulator: pass/fail and duration of each;
#   (e) wall-clock times: xcodegen, build-for-testing, each boot and test run, and the total.
# xcodebuild output goes to files in the output directory; only a tail -40 is printed on a
# failure. Exits 0 when every check holds, else 1; the last line is the summary.
#
# Written for macOS's /bin/bash 3.2: no associative arrays, no empty-array expansions.
set -euo pipefail
cd "$(dirname "$0")/.."

TOTAL_START=$(date +%s)
OUT=${MACSERVE_OUTPUT:-$PWD/bft-facts-out}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
exec > >(tee -a "$OUT/facts.txt") 2>&1

DD="$PWD/.bft-dd"
PRODUCTS="$DD/Build/Products"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bft-facts.XXXXXX")
TYPES=com.apple.CoreSimulator.SimDeviceType
RUNTIMES="com.apple.CoreSimulator.SimRuntime.iOS-27-0 com.apple.CoreSimulator.SimRuntime.iOS-27-1"
# One short UI test that has passed on both the iPhone and the iPad (PR #694's ipad and
# iphone-app shard results: 17.4 s and 10.6 s). BFT_TEST=Class/testMethod overrides it.
TEST=${BFT_TEST:-ChatUXSmokeTests/testFinishedPlanShowsOnlyItsHeader}
TEST_CLASS=${TEST%%/*}
TEST_METHOD=${TEST#*/}
# The root-installed XcodeGen macserve's xcodegen step runs; macserve's PATH has no Homebrew.
XCODEGEN=$(command -v xcodegen || echo /Library/macserve/tools/xcodegen)
# GNU timeout where installed, else Tools/ci/timeout.py (the same options, in Python).
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || echo "$PWD/Tools/ci/timeout.py")

FAILS=""
TIMES=""
CREATED=""
fail() { FAILS="$FAILS; $*"; echo "FAIL: $*"; }
timing() { TIMES="$TIMES$(printf '  %-34s %5ss' "$1" "$2")"$'\n'; }
section() { printf '\n== %s ==\n' "$*"; }
# show_tail LOG: the last 40 lines of a failed step's log.
show_tail() { echo "--- tail -40 $1 ---"; tail -40 "$1" || true; echo "--- end ---"; }

# shellcheck disable=SC2317 # run by the EXIT trap
cleanup() {
  local udid
  for udid in $CREATED; do
    "$TIMEOUT_BIN" 120 xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    "$TIMEOUT_BIN" 120 xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  done
  [ ! -f "$OUT/build-for-testing.log" ] || gzip -f "$OUT/build-for-testing.log" || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# create NAME DEVICE_TYPE: a new simulator of DEVICE_TYPE on the first runtime in RUNTIMES that
# accepts it, in NEW_UDID (not printed: CREATED must be set outside a subshell). Never a
# substitute type.
create() {
  local name="$1" type="$2" runtime
  NEW_UDID=""
  for runtime in $RUNTIMES; do
    if NEW_UDID=$(xcrun simctl create "bft-$name-${MACSERVE_JOB_ID:-local}" "$TYPES.$type" "$runtime" 2>/dev/null); then
      CREATED="$CREATED $NEW_UDID"
      echo "$name: created $NEW_UDID ($type, $runtime)"
      return 0
    fi
  done
  NEW_UDID=""
  echo "$name: no runtime in $RUNTIMES accepts $type"
  return 1
}

# device_line UDID: simctl's line for UDID, e.g. "iPhone 18 Pro (UDID) (Booted)".
device_line() { xcrun simctl list devices | grep -F "($1)" | sed 's/^ *//' || true; }

# boot LABEL UDID: boots UDID unless it is booted, and waits for it; records the time.
boot() {
  local label="$1" udid="$2" start
  start=$(date +%s)
  if ! device_line "$udid" | grep -q '(Booted)'; then
    "$TIMEOUT_BIN" --signal=TERM --kill-after=5s 600s xcrun simctl boot "$udid" >>"$OUT/boot-$label.log" 2>&1 || true
  fi
  if ! "$TIMEOUT_BIN" --signal=TERM --kill-after=5s 600s xcrun simctl bootstatus "$udid" -b >>"$OUT/boot-$label.log" 2>&1; then
    timing "boot $label" $(($(date +%s) - start))
    fail "$label simulator $udid did not boot"
    show_tail "$OUT/boot-$label.log"
    return 1
  fi
  timing "boot $label" $(($(date +%s) - start))
  echo "$label: $(device_line "$udid")"
}

# run_test LABEL UDID: TEST from the one xctestrun on UDID; PASS only when that test case
# itself passed (not skipped, not a run of zero tests).
run_test() {
  local label="$1" udid="$2" start secs status=0
  local log="$OUT/test-$label.log"
  start=$(date +%s)
  "$TIMEOUT_BIN" --signal=INT --kill-after=15s 15m xcodebuild test-without-building \
      -xctestrun "$XCTESTRUN" \
      -destination "id=$udid" \
      -only-testing:"HerdrUITests/$TEST_CLASS/$TEST_METHOD" \
      -parallel-testing-enabled NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 300 \
      -resultBundlePath "$WORK/$label.xcresult" \
      >"$log" 2>&1 || status=$?
  secs=$(($(date +%s) - start))
  timing "test-without-building $label" "$secs"
  if [ "$status" -eq 0 ] && grep -q "^Test Case '-\[HerdrUITests\.$TEST_CLASS $TEST_METHOD\]' passed" "$log"; then
    echo "$label: PASS HerdrUITests/$TEST in ${secs}s (xctest $(grep -m1 "^Test Case '-\[HerdrUITests\.$TEST_CLASS $TEST_METHOD\]' passed" "$log" | sed 's/.*passed (\([^)]*\)).*/\1/'))"
  else
    fail "$label: HerdrUITests/$TEST did not pass (xcodebuild exit $status, ${secs}s)"
    show_tail "$log"
  fi
}

section "environment"
echo "job: ${MACSERVE_JOB_ID:-local}; output: $OUT; derived data: $DD"
xcodebuild -version | head -2 | tr '\n' ' '; echo
echo "xcodegen: $XCODEGEN; test for (d): HerdrUITests/$TEST"

section "xcodegen"
start=$(date +%s)
if "$XCODEGEN" generate >"$OUT/xcodegen.log" 2>&1; then
  timing xcodegen $(($(date +%s) - start))
  echo "xcodegen generate: ok"
else
  timing xcodegen $(($(date +%s) - start))
  fail "xcodegen generate failed"
  show_tail "$OUT/xcodegen.log"
fi

XCTESTRUN=""
if [ -z "$FAILS" ]; then
  section "build-for-testing"
  # Packages: the template's resolved SourcePackages next to its Debug build when there is
  # one (as macserve-ipad-script.sh links them), else a local clone directory.
  if [ -n "${MACSERVE_APP_DIR:-}" ] && [ -d "$MACSERVE_APP_DIR/../../../SourcePackages" ]; then
    PACKAGES=$(cd "$MACSERVE_APP_DIR/../../../SourcePackages" && pwd)
  else
    PACKAGES="$PWD/SourcePackages"
  fi
  echo "packages: $PACKAGES"
  rm -rf "$DD"
  start=$(date +%s)
  if "$TIMEOUT_BIN" --signal=INT --kill-after=15s 45m \
      xcodebuild -project Herdr.xcodeproj -scheme Herdr -configuration Debug \
        -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$PACKAGES" \
        ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build-for-testing >"$OUT/build-for-testing.log" 2>&1; then
    timing build-for-testing $(($(date +%s) - start))
    echo "build-for-testing: ok in $(($(date +%s) - start))s"
  else
    timing build-for-testing $(($(date +%s) - start))
    fail "build-for-testing failed"
    show_tail "$OUT/build-for-testing.log"
  fi
fi

if [ -z "$FAILS" ]; then
  section "(a) Build/Products size"
  du -sh "$PRODUCTS"
  echo "total KiB: $(du -sk "$PRODUCTS" | cut -f1)"
  for entry in "$PRODUCTS"/*; do du -sh "$entry"; done

  section "(b) .xctestrun files"
  find "$PRODUCTS" -name '*.xctestrun' >"$WORK/xctestruns"
  count=$(wc -l <"$WORK/xctestruns" | tr -d ' ')
  echo "count: $count"
  while IFS= read -r file; do
    echo "$file"
    plutil -p "$file" >"$WORK/plist" 2>&1 || fail "plutil -p $(basename "$file") failed: $(head -1 "$WORK/plist")"
    sed -n 's/^ *"BlueprintName" => "\(.*\)"$/\1/p' "$WORK/plist" | sort -u >"$WORK/targets"
    echo "  test targets: $(tr '\n' ' ' <"$WORK/targets")"
    for target in HerdrUITests HerdrFontTests; do
      grep -qx "$target" "$WORK/targets" || fail "$(basename "$file") has no $target"
    done
    cp "$file" "$OUT/" || true
  done <"$WORK/xctestruns"
  if [ "$count" -eq 1 ]; then
    XCTESTRUN=$(cat "$WORK/xctestruns")
  else
    fail "found $count .xctestrun files under Products, not 1"
  fi

  section "(c) symlinks under Products"
  find "$PRODUCTS" -type l >"$WORK/links"
  links=$(wc -l <"$WORK/links" | tr -d ' ')
  head -50 "$WORK/links"
  [ "$links" -le 50 ] || echo "... and $((links - 50)) more"
  echo "count: $links"
  [ "$links" -eq 0 ] || fail "$links symlinks under Products, not 0"
fi

if [ -n "$XCTESTRUN" ]; then
  section "(d) one generic build on iPhone 18 Pro and iPad"
  IPHONE=""
  IPAD=""
  if [ -n "${MACSERVE_SIMULATOR_ID:-}" ] && device_line "$MACSERVE_SIMULATOR_ID" | grep -q '^iPhone 18 Pro ('; then
    IPHONE=$MACSERVE_SIMULATOR_ID
    echo "iphone: the template's simulator $IPHONE"
  elif create iphone iPhone-18-Pro; then
    IPHONE=$NEW_UDID
  else
    fail "no iPhone 18 Pro simulator"
  fi
  if create ipad iPad-Pro-13-inch-M5-12GB; then
    IPAD=$NEW_UDID
  else
    fail "no iPad simulator"
  fi
  if [ -n "$IPHONE" ] && boot iphone "$IPHONE"; then run_test iphone "$IPHONE"; fi
  if [ -n "$IPAD" ] && boot ipad "$IPAD"; then run_test ipad "$IPAD"; fi
fi

section "(e) wall-clock times"
timing total $(($(date +%s) - TOTAL_START))
printf '%s' "$TIMES"

echo
if [ -z "$FAILS" ]; then
  echo "BFT-FACTS PASS: 1 xctestrun with HerdrUITests and HerdrFontTests, 0 symlinks, HerdrUITests/$TEST passed on iPhone 18 Pro and iPad from one generic build"
  exit 0
fi
echo "BFT-FACTS FAIL:${FAILS#;}"
exit 1
