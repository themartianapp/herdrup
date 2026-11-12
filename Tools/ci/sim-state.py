#!/usr/bin/env python3
"""Reads `xcrun simctl` JSON for Tools/ci/ui-shard.sh.

  sim-state.py device DEVICES_JSON UDID
      Prints the device's state, Booted or Shutdown. Exits 3 when the device is listed but
      unavailable (its runtime is gone, actions/runner-images#14946) and 1 when it is
      missing, listed twice or in any other state.

  sim-state.py runtimes RUNTIMES_JSON DEVICES_JSON UDID
      Prints the line of the runtime that device runs on (or of every iOS runtime when the
      lists name it differently). Exits 0 when it is Ready and mounted, else 1.

DEVICES_JSON is `simctl list devices --json`; RUNTIMES_JSON is `simctl runtime list -j`.
"""
import json
import os
import sys


def load(path):
    with open(path) as source:
        return json.load(source)


def find_device(devices_json, udid):
    devices = devices_json["devices"]
    if not isinstance(devices, dict) or any(not isinstance(group, list) for group in devices.values()):
        raise ValueError("invalid devices inventory")
    matches = [(runtime, device) for runtime, group in devices.items() for device in group
               if device.get("udid") == udid]
    if len(matches) != 1:
        raise ValueError("target missing or duplicated in device inventory")
    return matches[0]


def device(devices_path, udid):
    try:
        runtime, entry = find_device(load(devices_path), udid)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print("invalid simulator inventory for %s: %s" % (udid, error), file=sys.stderr)
        return 1
    if entry.get("isAvailable") is not True:
        print("%s is unavailable on %s: %s" % (udid, runtime, entry.get("availabilityError", "no reason given")),
              file=sys.stderr)
        return 3
    state = entry.get("state")
    if state not in ("Booted", "Shutdown"):
        print("%s has unsupported or missing state: %r" % (udid, state), file=sys.stderr)
        return 1
    print(state)
    return 0


def mounted(path):
    # mountPath can name a symlink to the cryptex mount; a runtime counts as mounted when its
    # volume is a mount point or still holds the runtime bundle.
    real = os.path.realpath(path)
    return os.path.ismount(real) or os.path.isdir(os.path.join(real, "Library/Developer/CoreSimulator/Profiles/Runtimes"))


def runtimes(runtimes_path, devices_path, udid):
    try:
        listed = load(runtimes_path)
        if not isinstance(listed, dict):
            raise ValueError("runtime list is not an object")
        target = find_device(load(devices_path), udid)[0]
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print("unreadable runtime list: %s" % error)
        return 1
    judged = []  # (identifier, is iOS, ready, line)
    for key, runtime in sorted(listed.items()):
        identifier = runtime.get("runtimeIdentifier") or runtime.get("identifier") or key
        state = str(runtime.get("state", "missing state"))
        path = runtime.get("mountPath")
        name = "%s (%s)" % (identifier.rsplit(".", 1)[-1], runtime.get("build", "?"))
        if state.startswith("Unusable"):
            print("%s: %s (ignored)" % (name, state))
            continue
        ready = state == "Ready" and (path is None or mounted(path))
        where = "mount not reported" if path is None else ("mounted at " if mounted(path) else "NOT MOUNTED at ") + path
        judged.append((identifier, "iOS" in identifier, ready, "%s: %s, %s" % (name, state, where)))
    own = [entry for entry in judged if entry[0] == target]
    if not own:
        # The runtime list names runtimes differently from the device list: judge every
        # iOS runtime rather than none.
        print("no runtime listed as %s; judging every iOS runtime" % target)
        own = [entry for entry in judged if entry[1]]
    for _, _, _, line in own:
        print(line)
    return 0 if own and all(ready for _, _, ready, _ in own) else 1


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "device":
        sys.exit(device(sys.argv[2], sys.argv[3]))
    if len(sys.argv) == 5 and sys.argv[1] == "runtimes":
        sys.exit(runtimes(*sys.argv[2:]))
    print(__doc__, file=sys.stderr)
    sys.exit(64)
