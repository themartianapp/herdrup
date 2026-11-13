#!/usr/bin/env python3
"""Picks the simulators Tools/ci/ui-shard.sh runs on, for a shard run on any Mac.

    eval "$(python3 Tools/ci/pick-simulators.py)"

Reads `xcrun simctl list devices available --json` and prints `export` lines for
IPHONE_UDID, IPAD_UDID and IPAD11_UDID: the newest iOS runtime holding BOTH an iPhone
and an iPad (an iOS 27.1 install may hold only iPhone Duo), its iPad Pro 13-inch, and
the 1180x820 pt iPad that Herdrup Desktop's second reference size needs. It never
substitutes a different device: a missing one is an error.
"""
import json
import re
import subprocess
import sys


def main() -> None:
    listing = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        check=True, capture_output=True, text=True,
    ).stdout
    devices = json.loads(listing)["devices"]
    runtimes = [
        (tuple(map(int, match.group(1).split("-"))), name)
        for name in devices
        if (match := re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+)*)", name))
    ]

    def usable(name):
        available = [device for device in devices[name] if device.get("isAvailable", True)]
        phones = [device for device in available if device["name"].startswith("iPhone")
                  and "Duo" not in device["name"]]
        pads = [device for device in available if device["name"].startswith("iPad")]
        return phones, pads

    candidates = [(version, name) for version, name in runtimes if all(usable(name))]
    if not candidates:
        sys.exit("no iOS runtime has both an iPhone and an iPad; no substitute or skip")
    _, runtime = max(candidates)
    phones, pads = usable(runtime)
    ipad = next(
        (device for device in pads if "iPad Pro" in device["name"] and "13-inch" in device["name"]),
        pads[0],
    )
    # Herdrup Desktop's second reference size (DesktopReferenceShots): an 1180x820 pt
    # iPad at @2x. The iPad Air 11-inch is that size, and so is the base iPad (A16);
    # the iPad Pro 11-inch is not (1210x834).
    ipad11 = next(
        (device for device in pads if device["name"].startswith("iPad Air 11-inch")),
        next((device for device in pads if device["name"].startswith("iPad (A16)")), None),
    )
    if ipad11 is None:
        sys.exit(f"{runtime} has no 1180x820 iPad (iPad Air 11-inch or iPad (A16)); no substitute or skip")
    for key, device in [("IPHONE_UDID", phones[0]), ("IPAD_UDID", ipad), ("IPAD11_UDID", ipad11)]:
        print(f"export {key}={device['udid']}")
        print(f"{runtime}: {key}={device['udid']} ({device['name']})", file=sys.stderr)


if __name__ == "__main__":
    main()
