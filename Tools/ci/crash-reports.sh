#!/usr/bin/env bash
# The macserve script shard `crash-reports` (.macserve.json; template org-ios-sim-script-v1):
# the opt-in crash reports end to end in the built Debug app, then symbolicated.
#
# MetricKit delivers nothing in the simulator, and Xcode's Debug › Simulate MetricKit
# Payloads can't be scripted. A DEBUG launch with HERDR_CRASH_REPORT_URL (a stub relay) and
# HERDR_MOCK_METRICKIT_PAYLOAD (a recorded MXDiagnosticPayload JSON) feeds that payload through
# the same reporter MetricKit's subscriber uses (App/CrashReportsLaunch.swift). The payload is
# Tests/HerdrKitTests/Fixtures/metrickit-diagnostic-payload.json (build 238's real crash) with
# its two Herdr frames moved to CrashReportsLaunch.start() and .usageCountSwitched(on:) in
# THIS build's binary, so symbolication has a known answer. Rounds, each a fresh launch:
#   off      usage-count switch off, payload fed  -> the stub receives nothing, no queue
#   offline  switch on, payload fed, relay down   -> nothing received, 2 reports queued
#   flush    switch on, no payload, relay up      -> the 2 queued reports arrive
#   on       switch on, payload fed, relay up     -> 2 reports arrive (crash + hang)
# Then the built image gets a dSYM (dsymutil) and Tools/crash/symbolicate.py symbolicates the
# received crash report with atos; it must name both functions.
#
# Writes to MACSERVE_OUTPUT: received/*.json, dSYMs/, symbolicated/*.txt, RESULTS.md,
# FAILURES.txt, run.log. Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
: "${MACSERVE_SIMULATOR_ID:?run by the macserve script template, which sets MACSERVE_SIMULATOR_ID}"
: "${MACSERVE_APP_DIR:?run by the macserve script template, which sets MACSERVE_APP_DIR}"
: "${MACSERVE_OUTPUT:?run by the macserve script template, which sets MACSERVE_OUTPUT}"

APP="$MACSERVE_APP_DIR/Herdr.app"
OUT=$(mkdir -p "$MACSERVE_OUTPUT" && cd "$MACSERVE_OUTPUT" && pwd)
UDID=$MACSERVE_SIMULATOR_ID
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || echo Tools/ci/timeout.py)
PORT=$((20000 + RANDOM % 20000))
DOWN_PORT=$((PORT + 1))
SETTLE=${SETTLE:-20}
: > "$OUT/FAILURES.txt"
exec > >(tee -a "$OUT/run.log") 2>&1

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "FAILURE: $*"; printf '%s\n' "$*" >> "$OUT/FAILURES.txt"; }
t() { local secs=$1; shift; "$TIMEOUT_BIN" "$secs" "$@"; }

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist") || { echo "no app at $APP"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
# Xcode's Debug builds put the app's code in Herdr.debug.dylib beside a stub executable.
IMAGE="$APP/Herdr.debug.dylib"
[ -f "$IMAGE" ] || IMAGE="$APP/Herdr"
log "app $BUNDLE_ID $VERSION ($BUILD), code in $(basename "$IMAGE")"

python3 Tools/ci/crash_payload.py payload "$IMAGE" Tests/HerdrKitTests/Fixtures/metrickit-diagnostic-payload.json \
  "$VERSION" "$BUILD" "$OUT/payload.json" > "$OUT/expected.json" || { echo "payload failed"; exit 1; }
cat "$OUT/expected.json"

python3 Tools/ci/crash_payload.py serve "$PORT" "$OUT/received" &
STUB=$!
cleanup() {
  kill "$STUB" 2>/dev/null
  t 60 xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
}
trap cleanup EXIT

t 900 xcrun simctl boot "$UDID" 2>/dev/null
t 900 xcrun simctl bootstatus "$UDID" -b >/dev/null || { echo "bootstatus failed"; exit 1; }
t 300 xcrun simctl install "$UDID" "$APP" || { echo "install failed"; exit 1; }
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data) || { echo "no data container"; exit 1; }
QUEUE="$DATA/Library/Caches/CrashReports"
PREFS="$DATA/Library/Preferences/$BUNDLE_ID"
# The app reads the payload from its own container.
mkdir -p "$DATA/tmp" && cp "$OUT/payload.json" "$DATA/tmp/payload.json"

set_switch() { # on|off: the app's "Share anonymous usage count" (UsagePing.Key.enabled)
  local value=YES; [ "$1" = off ] && value=NO
  t 60 xcrun simctl spawn "$UDID" defaults write "$PREFS" usagePing.enabled -bool "$value"
  log "usagePing.enabled = $(t 60 xcrun simctl spawn "$UDID" defaults read "$PREFS" usagePing.enabled)"
}

launch() { # round relay-port feed-payload(yes|no)
  local round=$1 port=$2 feed=$3
  t 60 xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  # localhost, not 127.0.0.1: since iOS 17, ATS refuses plain HTTP to IP addresses but still
  # allows unqualified names.
  local env=(SIMCTL_CHILD_HERDR_CRASH_REPORT_URL="http://localhost:$port/$round/v1/crash")
  [ "$feed" = yes ] && env+=(SIMCTL_CHILD_HERDR_MOCK_METRICKIT_PAYLOAD="$DATA/tmp/payload.json")
  log "round $round: launch (relay port $port, payload $feed)"
  env "${env[@]}" "$TIMEOUT_BIN" 60 xcrun simctl launch "$UDID" "$BUNDLE_ID" || fail "$round: launch failed"
}

received() { find "$OUT/received" -name "$1-*.json" 2>/dev/null | wc -l | tr -d ' '; }
queued() { find "$QUEUE" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

wait_for() { # round count: waits up to SETTLE s for `count` reports
  local i
  for ((i = 0; i < SETTLE; i++)); do
    [ "$(received "$1")" -ge "$2" ] && break
    sleep 1
  done
  sleep 2 # anything extra
}

results=()
check() { # round expected-received expected-queued
  local got q
  got=$(received "$1"); q=$(queued)
  results+=("| $1 | $2 | $got | $3 | $q |")
  [ "$got" = "$2" ] || fail "$1: received $got reports, expected $2"
  [ "$q" = "$3" ] || fail "$1: $q reports queued, expected $3"
}

set_switch off
launch off "$PORT" yes
sleep "$SETTLE"
check off 0 0

set_switch on
launch offline "$DOWN_PORT" yes
sleep "$SETTLE"
check offline 0 2

launch flush "$PORT" no
wait_for flush 2
check flush 2 0

launch on "$PORT" yes
wait_for on 2
check on 2 0

# Each received report is exactly what CrashReport.body makes: no other keys.
python3 - "$OUT/received" <<'PY' || fail "a received report has unexpected fields"
import json, pathlib, sys
allowed = {"v", "kind", "version", "build", "os", "device", "exception", "termination", "hangSeconds",
           "truncated", "binaries", "stacks"}
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    report = json.loads(path.read_text())
    extra = set(report) - allowed
    print(path.name, report["kind"], report["version"], report["build"], report["device"], "extra:", sorted(extra))
    assert not extra and "claude-secret" not in path.read_text(), path
PY

log "dSYM"
mkdir -p "$OUT/dSYMs"
t 600 xcrun dsymutil "$IMAGE" -o "$OUT/dSYMs/$(basename "$IMAGE").dSYM" || fail "dsymutil failed"
xcrun dwarfdump --uuid "$OUT/dSYMs/$(basename "$IMAGE").dSYM" || true

log "symbolicate"
CRASH=$(grep -l '"kind":"crash"' "$OUT"/received/on-*.json | head -1)
if [ -n "$CRASH" ]; then
  python3 Tools/crash/symbolicate.py --report "$CRASH" --dsyms "$OUT/dSYMs" --out "$OUT/symbolicated" --symbolizer atos
  while IFS= read -r name; do
    grep -qF "$name" "$OUT"/symbolicated/*.txt || fail "symbolicated report does not name $name"
    log "symbolicated: $name"
  done < <(python3 -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))["expected"]))' "$OUT/expected.json")
else
  fail "no crash report received in round on"
fi

{
  echo "# Crash reports on macserve"
  echo
  echo "App $BUNDLE_ID $VERSION ($BUILD), simulator $UDID."
  echo
  echo "| round | expected received | received | expected queued | queued |"
  echo "| --- | --- | --- | --- | --- |"
  printf '%s\n' "${results[@]}"
  echo
  if [ -s "$OUT/FAILURES.txt" ]; then echo "**FAILED**"; sed 's/^/- /' "$OUT/FAILURES.txt"; else echo "**PASSED**"; fi
} > "$OUT/RESULTS.md"
cat "$OUT/RESULTS.md"
[ ! -s "$OUT/FAILURES.txt" ]
