#!/usr/bin/env bash
# Drags the conversation column's edge handles (Chat and Gram) on the iPhone Duo simulator's
# inner display, held wide and held tall, and checks the column follows the finger.
#
# Run by the macserve host's script template (org-ios-sim-script-v1, `.macserve.json` script
# shard "duo-column"), which builds the Debug app and sets MACSERVE_APP_DIR and
# MACSERVE_OUTPUT. Writes
#   duo-column/<pose>/<case>-before.png, -after.png   the inner display, via `duoctl screenshot`
#   duo-column/<pose>/<case>.json                     frames read before and after the drag
#   duo-column/<pose>/pose.state.json                 `duoctl state` once the pose was set
#   duo-column/RESULTS.md                             one row per case: widths and verdict
#   duo-column/FAILURES.txt                           every case that did not resize
#   duo-column/run.log                                this script's output
#
# WHY duoctl, not XCUITest. XCUITest cannot fold the simulator, and tools that inject
# touches through the simulator's legacy HID path land them on the cover touchscreen
# (duoctl's README, "Touches"; duo-screenshots.sh never taps for the same reason). duoctl
# (pinned, as in duo-screenshots.sh) unfolds the device and dispatches through the active
# display's own touchscreen. Frames are read from the accessibility tree with AXe (pinned
# below); the DEBUG mock's width probes (`chat-column`, `chat-width-area`, ...) are
# accessibility elements for exactly this.
#
# Each case is a fresh launch (the mock starts from the default width, Wide), then one
# 120 pt drag of one handle inwards. A working handle narrows the column by twice the drag,
# down to the minimum; a case passes when the column narrowed by at least 60 pt. A
# conversation under 600 pt (ConversationColumnWidth.isResizable) passes with no handles and
# its column at the whole width; with handles that do not move it, it fails.

set -uo pipefail

APP=${APP:-${MACSERVE_APP_DIR:+$MACSERVE_APP_DIR/Herdr.app}}
APP=${APP:-.build-dd/Build/Products/Debug-iphonesimulator/Herdr.app}
OUT=${OUT:-${MACSERVE_OUTPUT:-duo-column}}
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-1
# skarol/duoctl "Release 0.2.1", as in duo-screenshots.sh.
DUOCTL_REPO=https://github.com/skarol/duoctl.git
DUOCTL_SHA=c6ff3e961a9858fb061907448e702d7d1617dc4a
# cameroncooke/AXe v2.0.3 (universal build): duoctl's `elements` reads the tree through it.
AXE_URL=https://github.com/cameroncooke/AXe/releases/download/v2.0.3/AXe-macOS-v2.0.3-universal.tar.gz
AXE_SHA256=778007e44129992c7e11cd159e71beffbb1ff6184075dec91b96248908dbfba4
SETTLE=${SETTLE:-6}

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
: > "$OUT/FAILURES.txt"
exec > >(tee -a "$OUT/run.log") 2>&1

WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/duo-column.XXXXXX")
export XDG_CACHE_HOME="$WORK/cache"   # duoctl caches its compiled helper here

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "FAILURE: $*"; printf '%s\n' "$*" >> "$OUT/FAILURES.txt"; }
# Bounded: GNU timeout where present, else perl's alarm (macserve's PATH has no Homebrew).
t() {
  local secs=$1; shift
  if command -v gtimeout >/dev/null 2>&1; then gtimeout -k 15 "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

log "fetching duoctl at $DUOCTL_SHA"
git init -q "$WORK/duoctl"
git -C "$WORK/duoctl" fetch -q --depth 1 "$DUOCTL_REPO" "$DUOCTL_SHA"
git -C "$WORK/duoctl" checkout -q FETCH_HEAD
[ "$(git -C "$WORK/duoctl" rev-parse HEAD)" = "$DUOCTL_SHA" ] || { echo "duoctl is not at $DUOCTL_SHA"; exit 1; }

log "fetching AXe"
mkdir -p "$WORK/axe"
curl -fsSL --retry 3 -o "$WORK/axe.tgz" "$AXE_URL" || { echo "AXe download failed"; exit 1; }
[ "$(shasum -a 256 "$WORK/axe.tgz" | cut -d' ' -f1)" = "$AXE_SHA256" ] || { echo "AXe checksum mismatch"; exit 1; }
tar xzf "$WORK/axe.tgz" -C "$WORK/axe"
export PATH="$WORK/duoctl/bin:$WORK/axe:$PATH"
duoctl --version
axe --version || true

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist") || {
  echo "no app at $APP"; exit 1; }
DEVICE_TYPE=$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
types = json.load(sys.stdin)["devicetypes"]
print(next(t["identifier"] for t in types if "iPhone-Duo" in t["identifier"]))')
log "app $BUNDLE_ID, device type $DEVICE_TYPE, runtime $RUNTIME"

# Its own simulator, as duo-screenshots.sh does: macserve's (MACSERVE_SIMULATOR_ID) is left alone.
UDID=$(xcrun simctl create "duo-column-$(date +%s)" "$DEVICE_TYPE" "$RUNTIME") || { echo "simctl create failed"; exit 1; }
export DUOCTL_UDID=$UDID
cleanup() { t 120 xcrun simctl shutdown "$UDID" 2>/dev/null; t 120 xcrun simctl delete "$UDID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
log "booting $UDID"
t 900 xcrun simctl boot "$UDID" || { echo "boot failed"; exit 1; }
t 900 xcrun simctl bootstatus "$UDID" -b >/dev/null || { echo "bootstatus failed"; exit 1; }
t 300 xcrun simctl install "$UDID" "$APP" || { echo "install failed"; exit 1; }
t 300 duoctl state || t 300 duoctl state || { echo "duoctl state failed"; exit 1; }

# Launches the app on a mock; extra arguments go to the app (the argument domain). The
# chatview mock opens herdr-app's chat (pane w9:p1) as a notification tap would, so the chat
# shows beside the agent list (or the rail) without a tap on the list.
launch() { # <mock> [app arguments...]
  local mock=$1 tap=; shift
  [ "$mock" = chatview ] && tap='{"pane_id":"w9:p1"}'
  t 60 xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  SIMCTL_CHILD_HERDR_SCREENSHOT_MOCK=$mock SIMCTL_CHILD_HERDR_COLUMN_WIDTH_READOUT_HOLD=8 \
    SIMCTL_CHILD_HERDR_MOCK_PUSH_TAP=$tap SIMCTL_CHILD_HERDR_MOCK_STILL=1 \
    t 60 xcrun simctl launch "$UDID" "$BUNDLE_ID" ${1+"$@"} || return 1
  sleep "$SETTLE"
}
export -f launch t log
export UDID BUNDLE_ID SETTLE

# Unfold with the app in front (a sweep: an instant jump wedges the iOS 27.1 runtime).
launch chatview || { echo "launch failed"; exit 1; }
t 300 duoctl open --duration 1.5 || { echo "duoctl open failed"; exit 1; }

for pose in wide tall; do
  dir=$OUT/$pose; mkdir -p "$dir"
  ui=landscape; [ "$pose" = tall ] && ui=portrait
  log "=== pose $pose (inner display, interface $ui)"
  if ! t 300 duoctl rotate "$ui"; then fail "$pose: duoctl rotate $ui failed"; continue; fi
  t 300 duoctl state > "$dir/pose.state.json" || { fail "$pose: duoctl state failed"; continue; }
  if ! python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(s.get("activeScreen") != "inner")' "$dir/pose.state.json"; then
    fail "$pose: the inner display is not active: $(cat "$dir/pose.state.json")"; continue
  fi
  python3 - "$dir" "$pose" <<'PY' || fail "$pose: driver crashed"
import json, os, subprocess, sys, time
out, pose = sys.argv[1], sys.argv[2]
DRAG = 120

def sh(*args, timeout=300):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

def elements():
    for _ in range(3):
        r = sh("duoctl", "elements")
        if r.returncode == 0:
            return json.loads(r.stdout)
        time.sleep(2)
    raise RuntimeError("duoctl elements: " + r.stderr)

def frame(els, ident):
    hits = [e["frame"] for e in els if e.get("identifier") == ident]
    return min(hits, key=lambda f: f["width"] * f["height"]) if hits else None

def label(els, ident):
    return next((e.get("label") for e in els if e.get("identifier") == ident), None)

def read(els, surface):
    return {k: frame(els, f"{surface}-{k}") for k in
            ("column", "width-area", "width-handle-left", "width-handle-right")} | {
            "readout": label(els, f"{surface}-width-readout")}

def failure(text):
    print("FAILURE:", text, flush=True)
    with open(os.path.join(os.path.dirname(out), "FAILURES.txt"), "a") as f:
        f.write(text + "\n")

cases = [("chat", "chatview", [], "left"), ("chat", "chatview", [], "right"),
         ("chat-rail", "chatview", ["-ui.sidebarMinimized", "YES"], "left"),
         ("gram", "gram", [], "left"), ("gram", "gram", [], "right")]
rows = []
for name, mock, args, edge in cases:
    surface = name.split("-")[0]
    case = f"{name}-{edge}"
    r = sh("bash", "-c", 'launch "$@"', "launch", mock, *args)
    if r.returncode:
        failure(f"{pose}/{case}: launch failed {r.stderr}"); continue
    els = elements()
    before = read(els, surface)
    sh("duoctl", "screenshot", os.path.join(out, f"{case}-before.png"))
    record = {"pose": pose, "case": case, "before": before, "elements_before": els}
    handle = before[f"width-handle-{edge}"]
    area = before["width-area"]
    if not handle and area and area["width"] < 600:
        # Too narrow to resize (ConversationColumnWidth.isResizable): no handles, shown whole.
        whole = before["column"] and abs(before["column"]["width"] - area["width"]) < 1
        verdict = "no handles, shown whole" if whole else "NO HANDLES, NOT WHOLE"
        if not whole:
            failure(f"{pose}/{case}: no handles on a {area['width']:g} pt {surface}, column {before['column']}")
        json.dump(record, open(os.path.join(out, case + ".json"), "w"), indent=1)
        rows.append((pose, case, before, None, verdict))
        print(pose, case, verdict, flush=True)
        continue
    if not handle or not before["column"]:
        record["error"] = "handle or column probe not in the accessibility tree"
        json.dump(record, open(os.path.join(out, case + ".json"), "w"), indent=1)
        failure(f"{pose}/{case}: {record['error']}")
        rows.append((pose, case, before, None, "no handle"))
        continue
    x = handle["x"] + handle["width"] / 2
    y = handle["y"] + handle["height"] / 2
    inward = DRAG if edge == "left" else -DRAG
    r = sh("duoctl", "swipe", f"{x:.1f}", f"{y:.1f}", f"{x + inward:.1f}", f"{y:.1f}", "--duration", "0.8")
    record["swipe"] = [x, y, x + inward, y, r.returncode, r.stdout + r.stderr]
    time.sleep(1.5)
    els = elements()
    after = read(els, surface)
    sh("duoctl", "screenshot", os.path.join(out, f"{case}-after.png"))
    record |= {"after": after, "elements_after": els}
    json.dump(record, open(os.path.join(out, case + ".json"), "w"), indent=1)
    w0, w1 = before["column"]["width"], (after["column"] or {}).get("width", -1)
    verdict = "resized" if w1 <= w0 - 60 else "NOT RESIZED"
    if verdict != "resized":
        failure(f"{pose}/{case}: column {w0:g} -> {w1:g} pt after a {DRAG} pt drag "
                f"(area {before['width-area'] and before['width-area']['width']})")
    rows.append((pose, case, before, after, verdict))
    print(pose, case, w0, "->", w1, verdict, flush=True)

with open(os.path.join(out, "rows.json"), "w") as f:
    json.dump(rows, f)
PY
done

t 60 xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
def w(f): return "-" if not f else f"{f['width']:g}"
def x(f): return "-" if not f else f"{f['x']:g}..{f['x'] + f['width']:g}"
lines = ["# Column handles on the iPhone Duo inner display", "",
         "| pose | case | area | column before | handles before (x) | column after | readout after | verdict |",
         "|---|---|---|---|---|---|---|---|"]
for pose in ("wide", "tall"):
    try:
        rows = json.load(open(os.path.join(out, pose, "rows.json")))
    except Exception:
        lines.append(f"| {pose} | (no results) | | | | | | |"); continue
    for _, case, b, a, verdict in rows:
        hl = f"{x(b['width-handle-left'])} / {x(b['width-handle-right'])}"
        lines.append(f"| {pose} | {case} | {w(b['width-area'])} | {w(b['column'])} | {hl} | "
                     f"{w(a and a['column'])} | {(a or {}).get('readout') or '-'} | {verdict} |")
open(os.path.join(out, "RESULTS.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

log "failures:"; cat "$OUT/FAILURES.txt"
[ ! -s "$OUT/FAILURES.txt" ]
