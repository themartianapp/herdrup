#!/usr/bin/env python3
"""Helpers for Tools/ci/crash-reports.sh (macserve script shard `crash-reports`).

  crash_payload.py payload IMAGE FIXTURE VERSION BUILD OUT
      Writes OUT: the recorded MXDiagnosticPayload FIXTURE (Tests/HerdrKitTests/Fixtures) with
      its Herdr frames moved into the built app: IMAGE's name and UUID, and the offsets of
      CrashReportsLaunch.start() and CrashReportsLaunch.usageCountSwitched(on:) in it (from
      `nm`), plus the built VERSION and BUILD. Prints the expected symbol names.
  crash_payload.py serve PORT DIR
      A stub relay: each POST to /<round>/v1/crash is saved as DIR/<round>-<n>.json, 204."""
import http.server
import json
import pathlib
import platform
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "crash"))
from symbolicate import macho_slices  # noqa: E402

SYMBOLS = ["18CrashReportsLaunchO5startyyFZ", "18CrashReportsLaunchO18usageCountSwitched2onySb_tFZ"]


def payload(image, fixture, version, build, out):
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    slices = {a: (uuid, vmaddr) for a, uuid, vmaddr in macho_slices(image)}
    uuid, vmaddr = slices.get(arch) or next(iter(slices.values()))
    names = subprocess.run(["nm", "-arch", arch, image], capture_output=True, text=True, check=True).stdout.splitlines()
    # Function symbols of CrashReportsLaunch, the two named first when present.
    ours = [line for line in names if "$s5Herdr18CrashReportsLaunchO" in line and line.split()[1:2] in (["T"], ["t"])]
    ours.sort(key=lambda line: next((i for i, s in enumerate(SYMBOLS) if line.endswith(s)), len(SYMBOLS)))
    if len(ours) < 2:
        sys.exit(f"no CrashReportsLaunch functions in {image}")
    # Four bytes in: an instruction inside the function, as a return address is.
    offsets = [int(line.split()[0], 16) - vmaddr + 4 for line in ours[:2]]
    data = json.loads(pathlib.Path(fixture).read_text())
    for diagnostic in data["crashDiagnostics"] + data["hangDiagnostics"]:
        diagnostic["diagnosticMetaData"].update(appVersion=version, appBuildVersion=build)
    herdr = 0
    node = data["crashDiagnostics"][0]["callStackTree"]["callStacks"][0]["callStackRootFrames"][0]
    while node:
        if node["binaryName"] == "Herdr":
            node.update(binaryName=pathlib.Path(image).name, binaryUUID=uuid,
                        offsetIntoBinaryTextSegment=offsets[herdr], address=0x100000000 + offsets[herdr])
            herdr += 1
        node = (node.get("subFrames") or [None])[0]
    assert herdr == 2, herdr
    pathlib.Path(out).write_text(json.dumps(data, indent=1))
    print(json.dumps({"image": pathlib.Path(image).name, "uuid": uuid, "arch": arch, "vmaddr": hex(vmaddr),
                      "offsets": offsets}))


def serve(port, directory):
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            parts = self.path.strip("/").split("/")
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if len(parts) == 3 and parts[1:] == ["v1", "crash"]:
                n = len(list(directory.glob(parts[0] + "-*.json"))) + 1
                (directory / f"{parts[0]}-{n}.json").write_bytes(body)
                self.send_response(204)
            else:
                self.send_response(404)
            self.end_headers()

        def log_message(self, *args):
            pass

    http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()


if __name__ == "__main__":
    command, *rest = sys.argv[1:]
    {"payload": payload, "serve": serve}[command](*rest)
