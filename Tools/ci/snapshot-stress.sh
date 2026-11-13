#!/usr/bin/env bash
# The macserve script shard `snapshot-stress` (.macserve.json; template org-ios-sim-script-v1):
# hours of use played in minutes, then the relayouts iOS forces when it snapshots the app
# going to the background, timed.
#
# The owner's phone killed the app in the background with 0x8BADF00D ("scene-update watchdog
# transgression ... 10.00 seconds"): iOS snapshots the scene in the other orientation and the
# other appearance, each a full SwiftUI relayout on the main thread, and after hours of use
# the tree was so large that one took more than ten seconds. This run launches the Debug app
# over the `chatview` mock with HERDR_SNAPSHOT_STRESS (App/SnapshotStress.swift): agents whose
# transcripts keep growing, fronted again and again (Chat, a second Chat, a terminal, Gram).
# Every few rounds the app writes its footprint, layer/view/WKWebView counts, chat rows held
# and drawn, and the main thread's longest block while it turns to landscape and back and
# while its appearance flips. Then Settings is launched over it, sending Herdr to the
# background, where the simulator takes its snapshots: the app writes the longest block from
# resigning active until four seconds in.
#
# Passes when, at the last round: layers <= MAX_LAYERS, phys_footprint <= MAX_FOOTPRINT_MB,
# every relayout and the background block <= MAX_BLOCK_MS, and layers grew by at most
# MAX_LAYER_GROWTH times from the first measurement.
#
# Writes to MACSERVE_OUTPUT: snapshot-stress.jsonl, RESULTS.md, FAILURES.txt, run.log; if the app
# dies mid-run, death/ (its crash reports since launch and the last two minutes of its log).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
: "${MACSERVE_SIMULATOR_ID:?run by the macserve script template, which sets MACSERVE_SIMULATOR_ID}"
: "${MACSERVE_APP_DIR:?run by the macserve script template, which sets MACSERVE_APP_DIR}"
: "${MACSERVE_OUTPUT:?run by the macserve script template, which sets MACSERVE_OUTPUT}"

APP="$MACSERVE_APP_DIR/Herdr.app"
OUT=$(mkdir -p "$MACSERVE_OUTPUT" && cd "$MACSERVE_OUTPUT" && pwd)
UDID=$MACSERVE_SIMULATOR_ID
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || echo Tools/ci/timeout.py)
ROUNDS=${ROUNDS:-30}
EVERY=${EVERY:-5}
GROWTH=${GROWTH:-4}
MAX_LAYERS=${MAX_LAYERS:-4000}
MAX_FOOTPRINT_MB=${MAX_FOOTPRINT_MB:-600}
MAX_BLOCK_MS=${MAX_BLOCK_MS:-1000}
MAX_LAYER_GROWTH=${MAX_LAYER_GROWTH:-1.5}
: > "$OUT/FAILURES.txt"
exec > >(tee -a "$OUT/run.log") 2>&1

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "FAILURE: $*"; printf '%s\n' "$*" >> "$OUT/FAILURES.txt"; }
t() { local secs=$1; shift; "$TIMEOUT_BIN" "$secs" "$@"; }

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist") || { echo "no app at $APP"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
log "app $BUNDLE_ID $VERSION ($BUILD); $ROUNDS rounds, measured every $EVERY, $GROWTH turns per refresh"

trap 't 60 xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1' EXIT
t 900 xcrun simctl boot "$UDID" 2>/dev/null
t 900 xcrun simctl bootstatus "$UDID" -b >/dev/null || { echo "bootstatus failed"; exit 1; }
t 300 xcrun simctl install "$UDID" "$APP" || { echo "install failed"; exit 1; }
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data) || { echo "no data container"; exit 1; }
LINES="$DATA/tmp/snapshot-stress.jsonl"
rm -f "$LINES"
# Portrait, as the phone is held; the run turns it itself.
t 60 xcrun simctl ui "$UDID" appearance dark >/dev/null 2>&1

# Evidence for a run whose app died: the crash reports (.ips) written since launch, and the
# simulator's log of the app's last two minutes, trimmed. An overloaded host's kill leaves no
# report; a crash in the app does.
REPORTS="$HOME/Library/Logs/DiagnosticReports"
LAUNCH_MARK="$OUT/.launched"
collect_death_evidence() {
  mkdir -p "$OUT/death"
  sleep 5 # ReportCrash writes the .ips a moment after the process is gone
  find "$REPORTS" -maxdepth 2 -type f -iname '*herdr*' -newer "$LAUNCH_MARK" 2>/dev/null |
    while IFS= read -r report; do cp "$report" "$OUT/death/"; log "crash report: $(basename "$report")"; done
  [ -n "$(ls -A "$OUT/death" 2>/dev/null)" ] || log "no crash report for Herdr since launch"
  t 120 xcrun simctl spawn "$UDID" log show --last 2m --style compact --predicate 'process == "Herdr"' 2>&1 |
    tail -n 400 > "$OUT/death/log-show-last-2m.txt"
  log "simulator log: $(wc -l < "$OUT/death/log-show-last-2m.txt" | tr -d ' ') lines in death/log-show-last-2m.txt"
}

touch "$LAUNCH_MARK"
SIMCTL_CHILD_HERDR_SCREENSHOT_MOCK=chatview \
SIMCTL_CHILD_HERDR_MOCK_CHAT_ANSWERED="Yes, merge and deploy" \
SIMCTL_CHILD_HERDR_MOCK_CHAT_GROWTH="$GROWTH" \
SIMCTL_CHILD_HERDR_SNAPSHOT_STRESS="$ROUNDS" \
SIMCTL_CHILD_HERDR_SNAPSHOT_STRESS_EVERY="$EVERY" \
  t 60 xcrun simctl launch "$UDID" "$BUNDLE_ID" || { echo "launch failed"; exit 1; }

# A round fronts five screens, ~11 s; each measurement adds ~6 s.
DEADLINE=$(( $(date +%s) + 60 + ROUNDS * 20 ))
until grep -q '"done":true' "$LINES" 2>/dev/null; do
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then fail "the stress run did not finish in time"; break; fi
  if ! xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
    fail "the app is no longer running"
    collect_death_evidence
    break
  fi
  sleep 10
  [ -s "$LINES" ] && log "last: $(grep '"round"' "$LINES" | tail -1)"
done

if grep -q '"done":true' "$LINES" 2>/dev/null; then
  log "backgrounding: launching Settings over Herdr"
  t 60 xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null || fail "could not launch Settings"
  for _ in $(seq 1 20); do
    grep -q background_block_ms "$LINES" && break
    sleep 1
  done
  grep -q background_block_ms "$LINES" || fail "no background measurement"
fi
cp "$LINES" "$OUT/snapshot-stress.jsonl" 2>/dev/null

python3 - "$OUT/snapshot-stress.jsonl" "$MAX_LAYERS" "$MAX_FOOTPRINT_MB" "$MAX_BLOCK_MS" "$MAX_LAYER_GROWTH" \
  "$OUT/FAILURES.txt" > "$OUT/table.md" <<'PY'
import json, os, sys
path, max_layers, max_mb, max_ms, max_growth, failures = sys.argv[1:]
max_layers, max_mb, max_ms, max_growth = int(max_layers), float(max_mb), int(max_ms), float(max_growth)
lines = [json.loads(l) for l in open(path) if l.strip()] if os.path.exists(path) else []
rounds = [l for l in lines if "round" in l and "layers" in l]
background = [l for l in lines if "background_block_ms" in l]
cols = ["round", "footprint_mb", "layers", "views", "webviews", "webviews_in_window", "chat_rows", "chat_rows_drawn",
        "rotate_ms", "rotate_back_ms", "appearance_ms", "appearance_back_ms"]
print("| " + " | ".join(cols) + " |")
print("|" + " --- |" * len(cols))
for l in rounds:
    print("| " + " | ".join(str(l.get(c, "")) for c in cols) + " |")
for b in background:
    print(f"\nBackground (Settings launched over the app): longest main-thread block {b['background_block_ms']} ms, "
          f"footprint {b['footprint_mb']} MB, layers {b['layers']}, views {b['views']}.")
problems = []
measured = [l for l in rounds if l.get("round", 0) > 0]
if not measured:
    problems.append("no round was measured")
else:
    last = measured[-1]
    if last["layers"] > max_layers:
        problems.append(f"layers {last['layers']} > {max_layers} at round {last['round']}")
    if last["footprint_mb"] > max_mb:
        problems.append(f"phys_footprint {last['footprint_mb']} MB > {max_mb} MB at round {last['round']}")
    for key in ("rotate_ms", "rotate_back_ms", "appearance_ms", "appearance_back_ms"):
        worst = max((l.get(key, 0) for l in measured), default=0)
        if worst > max_ms:
            problems.append(f"{key} {worst} ms > {max_ms} ms")
    base = measured[0]["layers"]
    if base and last["layers"] / base > max_growth:
        problems.append(f"layers grew {last['layers'] / base:.2f}x ({base} -> {last['layers']}) > {max_growth}x")
    if any(l.get("rotated_to") != "landscape" for l in measured):
        problems.append("the scene did not turn to landscape in every measurement")
for b in background:
    if b["background_block_ms"] > max_ms:
        problems.append(f"background_block_ms {b['background_block_ms']} > {max_ms}")
with open(failures, "a") as f:
    for p in problems:
        f.write(p + "\n")
PY
report_status=$?
[ "$report_status" -eq 0 ] || fail "the report step exited $report_status (measurements unreadable); no verdict"

{
  echo "# Background snapshot stress on macserve"
  echo
  echo "App $BUNDLE_ID $VERSION ($BUILD), simulator $UDID; $ROUNDS rounds, $GROWTH turns per chat refresh."
  echo "Limits: layers <= $MAX_LAYERS, phys_footprint <= $MAX_FOOTPRINT_MB MB, each relayout <= $MAX_BLOCK_MS ms,"
  echo "layer growth <= ${MAX_LAYER_GROWTH}x."
  echo
  cat "$OUT/table.md"
  echo
  if [ -s "$OUT/FAILURES.txt" ]; then echo "**FAILED**"; sed 's/^/- /' "$OUT/FAILURES.txt"; else echo "**PASSED**"; fi
} > "$OUT/RESULTS.md"
cat "$OUT/RESULTS.md"
[ ! -s "$OUT/FAILURES.txt" ]
