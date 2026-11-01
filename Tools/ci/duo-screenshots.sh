#!/usr/bin/env bash
# Screenshots the app's main screens on the iPhone Duo simulator in each pose.
#
# Run by .github/workflows/duo-screenshots.yml after the Debug simulator build. Writes
#   duo-shots/<pose>/<screen>.png         the active display, via `duoctl screenshot`
#   duo-shots/<pose>/<screen>.state.json  `duoctl state` read right before the capture
#   duo-shots/<pose>/pose.state.json      `duoctl state` once the pose was set
#   duo-shots/POSES.md                    angle/orientation used and read back, per pose
#   duo-shots/FAILURES.txt                every pose or capture that did not verify
#   duo-shots/run.log                     this script's output
#
# WHY duoctl. `simctl` has no hinge or rotation command, and `simctl io screenshot` needs
# `--display` on the foldable. duoctl (MIT, pinned below) sends Device Hub's private hinge
# and orientation HID event and reads the result back. Touches land on the cover screen
# only, so every screen is reached by relaunching with the DEBUG screenshot mock
# (HERDR_SCREENSHOT_MOCK), never by tapping.
#
# THE HINGE MOVES ONLY A FEW TIMES. Each pose is set once, then the app is relaunched per
# screen. Every hinge change is a sweep (`--duration`): on the iOS 27.1 runtime an instant
# closed<->open jump leaves the simulator unable to switch screens until it is recreated.
# Partial angles keep whichever screen the sweep started on (the simulator switches at the
# ends of the travel), so tent sweeps up from closed (cover stays active) and laptop sweeps
# down from open (inner stays active). That is why the poses run in the order below.
#
# A pose whose hinge/screen does not verify is retried once on a recreated simulator, then
# recorded in FAILURES.txt and skipped. A pose whose interface refuses to rotate (the app
# is portrait-only on iPhone, so the cover screen stays portrait) is captured anyway, with
# the device orientation set directly, and noted in POSES.md rather than FAILURES.txt:
# that is the app's behaviour in the pose, and those images are what the owner sees.

set -uo pipefail

APP=${APP:-.build-dd/Build/Products/Debug-iphonesimulator/Herdr.app}
OUT=${OUT:-duo-shots}
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-1
# skarol/duoctl "Release 0.2.1" (supports the Xcode 27.1 image and the iOS 27.1 runtime).
DUOCTL_REPO=https://github.com/skarol/duoctl.git
DUOCTL_SHA=c6ff3e961a9858fb061907448e702d7d1617dc4a
SETTLE=${SETTLE:-6}          # seconds after launch before the capture
ANGLE_TOLERANCE=6            # degrees between the angle set and the angle read back
LAPTOP_ANGLE=130             # Device Hub's "Partially Open" preset
TENT_ANGLES="80 60 45"       # tried in order until the cover stays active

POSES="closed-portrait closed-landscape tent open open-rotated laptop"
# split: the Agents home with an agent's terminal open beside the list (a notification tap
# on w1:p1 fronts it). rail: the same with the list minimised to the icon rail, the
# terminal at full width. gram-unread: Gram with fourteen read messages newer than the
# three unread ones, so the opening position shows (the first unread, or the newest).
SCREENS="connect list split rail pane gram gram-unread settings onboarding"

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
: > "$OUT/FAILURES.txt"
exec > >(tee -a "$OUT/run.log") 2>&1

WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/duo.XXXXXX")
export XDG_CACHE_HOME="$WORK/cache"   # duoctl caches its compiled helper here

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "FAILURE: $*"; printf '%s\n' "$*" >> "$OUT/FAILURES.txt"; }

# Bounded so a wedged CoreSimulator call cannot eat the job's deadline.
t() { local secs=$1; shift; gtimeout -k 15 "$secs" "$@"; }

# ---------------------------------------------------------------- duoctl

log "fetching duoctl at $DUOCTL_SHA"
git init -q "$WORK/duoctl"
git -C "$WORK/duoctl" fetch -q --depth 1 "$DUOCTL_REPO" "$DUOCTL_SHA"
git -C "$WORK/duoctl" checkout -q FETCH_HEAD
[ "$(git -C "$WORK/duoctl" rev-parse HEAD)" = "$DUOCTL_SHA" ] || { echo "duoctl is not at $DUOCTL_SHA"; exit 1; }
export PATH="$WORK/duoctl/bin:$PATH"
duoctl --version

# duoctl's in-simulator helper, for the one thing duoctl has no command for: setting the
# DEVICE orientation directly when the app's interface refuses to rotate.
helper() {
  local bin
  bin=$(ls -t "$XDG_CACHE_HOME"/duoctl/duoctl-helper-* 2>/dev/null | head -1)
  [ -n "$bin" ] || { log "duoctl helper not built yet"; return 1; }
  t 60 xcrun simctl spawn "$UDID" "$bin" "$@"
}

# ---------------------------------------------------------------- simulator

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist") || {
  echo "no app at $APP"; exit 1; }
DEVICE_TYPE=$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
types = json.load(sys.stdin)["devicetypes"]
print(next(t["identifier"] for t in types if "iPhone-Duo" in t["identifier"]))')
log "app $BUNDLE_ID, device type $DEVICE_TYPE, runtime $RUNTIME"

UDID=
delete_sim() {
  [ -n "$UDID" ] || return 0
  t 120 xcrun simctl shutdown "$UDID" 2>/dev/null || true
  t 120 xcrun simctl delete "$UDID" || true
  UDID=
}

new_sim() {
  delete_sim
  UDID=$(xcrun simctl create "duo-shots-$(date +%s)" "$DEVICE_TYPE" "$RUNTIME") || return 1
  export DUOCTL_UDID=$UDID
  log "booting $UDID"
  t 900 xcrun simctl boot "$UDID" || return 1
  t 900 xcrun simctl bootstatus "$UDID" -b || return 1
  t 300 xcrun simctl install "$UDID" "$APP" || return 1
  # The first duoctl call compiles its helper; the hinge is read back from then on.
  t 300 duoctl state
}

new_sim || { fail "simulator: could not create/boot a $DEVICE_TYPE on $RUNTIME"; exit 1; }

# The simulator is slow for a few minutes after its first boot: a 120 s `duoctl state`
# timed out in run 40740648537. So 300 s, and one more try.
state() { t 300 duoctl state || t 300 duoctl state; }
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

launch() { # <screen>
  t 60 xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  if [ "$1" = connect ]; then
    # A clean install, so no earlier mock run can leave state behind on the empty screen.
    t 120 xcrun simctl uninstall "$UDID" "$BUNDLE_ID" || true
    t 300 xcrun simctl install "$UDID" "$APP" || return 1
    t 60 xcrun simctl launch "$UDID" "$BUNDLE_ID" || return 1
  else
    # The mock name, then any extra environment and launch arguments the screen needs.
    # A subshell, so one screen's environment never reaches the next launch.
    (
      mock=$1; set --
      case $mock in
        split) mock=list; export SIMCTL_CHILD_HERDR_MOCK_PUSH_TAP='{"pane_id":"w1:p1"}' ;;
        rail)
          mock=list; export SIMCTL_CHILD_HERDR_MOCK_PUSH_TAP='{"pane_id":"w1:p1"}'
          # The argument domain overrides the stored preference for this launch only.
          set -- -ui.sidebarMinimized YES ;;
        gram-unread) mock=gram; export SIMCTL_CHILD_HERDR_MOCK_GRAM_NEWER=1 ;;
      esac
      export SIMCTL_CHILD_HERDR_SCREENSHOT_MOCK=$mock
      t 60 xcrun simctl launch "$UDID" "$BUNDLE_ID" ${1+"$@"}
    ) || return 1
  fi
  sleep "$SETTLE"
}

# ---------------------------------------------------------------- poses

# pose -> target angle, expected active screen, interface orientation, device orientation
# (the device orientation is the physical one, used only if the interface refuses to rotate)
pose_spec() {
  case $1 in
    closed-portrait)  echo "0 cover portrait portrait" ;;
    closed-landscape) echo "0 cover landscape landscape-left" ;;
    tent)             echo "${TENT_ANGLE:-80} cover landscape landscape-left" ;;
    open)             echo "180 inner landscape portrait" ;;
    open-rotated)     echo "180 inner portrait landscape-left" ;;
    laptop)           echo "$LAPTOP_ANGLE inner portrait landscape-left" ;;
  esac
}

# Moves the hinge for a pose, always as a sweep. Returns nonzero with duoctl's error.
move_hinge() { # <pose>
  case $1 in
    closed-*) t 300 duoctl close --duration 1 ;;
    open|open-rotated) t 300 duoctl open --duration 1.5 ;;
    laptop) t 300 duoctl open --duration 1.5 && t 300 duoctl hinge "$LAPTOP_ANGLE" --duration 1.5 ;;
    tent)
      # Up from closed, slowly (60 steps a second), so the cover stays the active screen.
      t 300 duoctl close --duration 1 && t 300 duoctl hinge "$TENT_ANGLE" --duration 3 ;;
  esac
}

verify_hinge() { # <state.json> <angle> <screen>; prints why not
  python3 - "$@" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); want, screen = float(sys.argv[2]), sys.argv[3]
problems = []
if s.get("activeScreen") != screen:
    problems.append(f"active screen is {s.get('activeScreen')}, wanted {screen}")
a = s.get("hingeAngle")
if a is None:
    problems.append("hinge angle unreadable")
elif abs(a - want) > float(__import__("os").environ.get("ANGLE_TOLERANCE", "6")):
    problems.append(f"hinge reads {a:g} deg, wanted {want:g}")
print("; ".join(problems))
sys.exit(1 if problems else 0)
PY
}

# Sets the pose with the connect screen in front, verifies it, and leaves
# $OUT/<pose>/pose.state.json and $OUT/<pose>/pose.notes behind.
set_pose() { # <pose>
  local pose=$1 dir=$OUT/$1 angle screen ui device err why
  read -r angle screen ui device <<<"$(pose_spec "$pose")"
  launch connect || { echo "app launch failed" > "$dir/pose.err"; return 1; }
  if ! err=$(move_hinge "$pose" 2>&1); then
    echo "$err"
    echo "hinge: $err" > "$dir/pose.err"
    return 2   # duoctl saw the screen not switch: the simulator may be stuck
  fi
  echo "$err"
  state > "$dir/pose.state.json" || { echo "duoctl state failed" > "$dir/pose.err"; return 1; }
  if ! why=$(ANGLE_TOLERANCE=$ANGLE_TOLERANCE verify_hinge "$dir/pose.state.json" "$angle" "$screen"); then
    echo "$why" > "$dir/pose.err"
    return 1
  fi
  if ! err=$(t 300 duoctl rotate "$ui" 2>&1); then
    # duoctl tried every device orientation; put the device back in the physical one.
    helper orientation "$device" || true
    sleep 1
    echo "rotate $ui: $err (device orientation set to $device directly)" >> "$dir/pose.notes"
  fi
  state > "$dir/pose.state.json" || { echo "duoctl state failed after rotation" > "$dir/pose.err"; return 1; }
  if ! why=$(ANGLE_TOLERANCE=$ANGLE_TOLERANCE verify_hinge "$dir/pose.state.json" "$angle" "$screen"); then
    echo "after rotation: $why" > "$dir/pose.err"
    return 1
  fi
  echo "angle=$angle screen=$screen ui=$ui device=$device" >> "$dir/pose.notes"
  return 0
}

for pose in $POSES; do
  dir=$OUT/$pose; mkdir -p "$dir"; rm -f "$dir/pose.err" "$dir/pose.notes"
  log "=== pose $pose"
  # Only tent has more than one angle to try; the other poses run the loop once.
  candidates=-
  [ "$pose" = tent ] && candidates=$TENT_ANGLES
  ok=
  for TENT_ANGLE in $candidates; do
    rm -f "$dir/pose.err"
    for attempt in 1 2; do
      set_pose "$pose"; rc=$?
      [ $rc -eq 0 ] && { ok=1; break; }
      log "pose $pose (attempt $attempt, angle $(pose_spec "$pose" | cut -d' ' -f1)): $(cat "$dir/pose.err" 2>/dev/null)"
      # Recreate only when duoctl reports the screen did not switch (the stuck case).
      [ $rc -eq 2 ] && [ $attempt -eq 1 ] || break
      log "recreating the simulator"
      new_sim || { fail "simulator: recreate failed during $pose"; exit 1; }
    done
    [ -n "$ok" ] && break
    [ "$pose" = tent ] && echo "tent at $TENT_ANGLE deg: $(cat "$dir/pose.err")" >> "$dir/pose.notes"
  done
  if [ -z "$ok" ]; then
    fail "$pose: pose did not verify: $(cat "$dir/pose.err" 2>/dev/null)"
    continue
  fi
  [ "$pose" = tent ] && echo "tent angle used: $TENT_ANGLE" >> "$dir/pose.notes"
  read -r pose_angle pose_screen pose_ui pose_device <<<"$(pose_spec "$pose")"

  for screen in $SCREENS; do
    log "--- $pose / $screen"
    if ! launch "$screen"; then fail "$pose/$screen: launch failed"; continue; fi
    if ! state > "$dir/$screen.state.json"; then fail "$pose/$screen: duoctl state failed twice (300 s each)"; continue; fi
    if ! why=$(ANGLE_TOLERANCE=$ANGLE_TOLERANCE verify_hinge "$dir/$screen.state.json" "$pose_angle" "$pose_screen"); then
      fail "$pose/$screen: $why"
      continue
    fi
    # The first capture after boot can take minutes (run 40731654683 lost one at 120 s),
    # so a timed-out capture gets one more, longer try.
    if ! err=$(t 300 duoctl screenshot "$dir/$screen.png" 2>&1) &&
       ! err=$(t 300 duoctl screenshot "$dir/$screen.png" 2>&1); then
      fail "$pose/$screen: screenshot: ${err:-timed out after 300 s}"; continue
    fi
    log "saved $dir/$screen.png ($(stat -f %z "$dir/$screen.png") bytes)"
  done
done

t 60 xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

# ---------------------------------------------------------------- POSES.md

python3 - "$OUT" "$POSES" "$SCREENS" <<'PY'
import json, os, sys
out, poses, screens = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
apple = {
    "closed-portrait": "closed (outer display, upright)",
    "closed-landscape": "closed, turned sideways",
    "tent": "tent (partially folded, set down on its edges, outer display faces you in landscape)",
    "open": "open wide (flat, inner display in landscape)",
    "open-rotated": "open tall (flat, turned a quarter, inner display in portrait)",
    "laptop": "laptop / seated (partially folded, inner display in portrait, fold horizontal)",
}
def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return None
def fmt(s):
    if not s:
        return "-"
    size = "x".join(f"{v:g}" for v in s.get("sizePoints") or [])
    angle = s.get("hingeAngle")
    return f"{'?' if angle is None else round(angle, 1)} deg, {s.get('activeScreen')}, {s.get('orientation')} ({s.get('rotation')}), {size} pt"
lines = ["# iPhone Duo poses used", "",
         "Each pose is set once with duoctl, then the app is relaunched per screen.",
         "Requested = what the script set; read back = `duoctl state` after the pose was set.", "",
         "| pose | Apple pose | requested (angle, screen, interface, fallback device orientation) | read back (angle, screen, interface, size) | notes |",
         "|---|---|---|---|---|"]
for pose in poses:
    d = os.path.join(out, pose)
    notes = open(os.path.join(d, "pose.notes")).read().strip().splitlines() if os.path.exists(os.path.join(d, "pose.notes")) else []
    req = next((n for n in notes if n.startswith("angle=")), "-")
    other = [n for n in notes if not n.startswith("angle=")]
    err = open(os.path.join(d, "pose.err")).read().strip() if os.path.exists(os.path.join(d, "pose.err")) else ""
    if err:
        other.append("FAILED: " + err)
    lines.append(f"| {pose} | {apple[pose]} | {req} | {fmt(load(os.path.join(d, 'pose.state.json')))} | {'<br>'.join(other).replace('|', '/')} |")
lines += ["", "## Read back per capture", "", "| pose | screen | read back | png |", "|---|---|---|---|"]
for pose in poses:
    for screen in screens:
        png = os.path.join(out, pose, screen + ".png")
        lines.append(f"| {pose} | {screen} | {fmt(load(os.path.join(out, pose, screen + '.state.json')))} | {'yes' if os.path.exists(png) else 'MISSING'} |")
lines += ["", "Book (partially folded, inner display in landscape, fold vertical) is the laptop",
          "angle with the open-wide orientation; it is not captured here."]
open(os.path.join(out, "POSES.md"), "w").write("\n".join(lines) + "\n")
PY

delete_sim
log "failures:"; cat "$OUT/FAILURES.txt"
[ ! -s "$OUT/FAILURES.txt" ]
