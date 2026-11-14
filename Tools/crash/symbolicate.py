#!/usr/bin/env python3
"""Symbolicates the opt-in crash and hang reports the app sends to the guest relay
(POST /v1/crash; GuestRelay/README.md "Crash reports").

A report carries, per thread, frames of [binary index, offset into the binary's __TEXT]
and, per binary, its name and UUID. This finds the dSYM whose UUID matches each binary,
adds the offset to that slice's __TEXT vmaddr and asks a symbolizer for function, file and
line: `atos` on a Mac (Xcode), else `llvm-symbolizer` (any LLVM 13+, also on Linux; it reads
Mach-O dSYMs). Frames in Apple's binaries print as `binary + offset`: their symbols live in
Xcode's device support files, not in our dSYMs.

Where reports come from:
  --report FILE ...        reports already on disk (a JSON body each)
  (default)                the relay's admin reads, with CRASH_ADMIN_TOKEN in the
                           environment: every report under --prefix (default today's)
Where dSYMs come from:
  --dsyms DIR ...          any directories holding *.dSYM bundles
  (default)                the TestFlight run's artifact dSYMs-<build> for each report's
                           build, through `gh api` (GitHub keeps it 90 days)

Examples:
  CRASH_ADMIN_TOKEN=... Tools/crash/symbolicate.py --prefix v1/2026-11-13/ --out /tmp/crashes
  Tools/crash/symbolicate.py --report r.json --dsyms ~/Downloads/dSYMs-245

Writes <out>/reports/<key>.json and <out>/<key>.txt per report and prints each .txt. Stdlib
only; needs `gh` only to fetch dSYMs, and atos or llvm-symbolizer to symbolicate."""
import argparse
import datetime
import io
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile

RELAY = "https://guest.herdrup.app"
REPO = "themartianapp/herdrup"
CPU = {0x0100000C: "arm64", 0x01000007: "x86_64", 0x0200000C: "arm64_32"}
ARM64E = 2  # cpusubtype of arm64e


# MARK: Mach-O


def macho_slices(path):
    """[(arch, UUID upper-case, __TEXT vmaddr)] for each slice of a Mach-O or fat file."""
    data = pathlib.Path(path).read_bytes()
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):  # fat, big-endian headers
        wide = magic == 0xCAFEBABF
        count = struct.unpack(">I", data[4:8])[0]
        slices, entry = [], 20 if not wide else 32
        for i in range(count):
            fields = data[8 + i * entry: 8 + (i + 1) * entry]
            offset = struct.unpack(">Q" if wide else ">I", fields[8:16] if wide else fields[8:12])[0]
            slices += thin_slice(data, offset)
        return slices
    return thin_slice(data, 0)


def thin_slice(data, base):
    magic = struct.unpack("<I", data[base:base + 4])[0]
    if magic != 0xFEEDFACF:  # 64-bit little-endian only: every arch the app ships
        return []
    cputype, cpusubtype, _, ncmds = struct.unpack("<iiII", data[base + 4:base + 20])
    arch = CPU.get(cputype & 0xFFFFFFFF, hex(cputype))
    if arch == "arm64" and (cpusubtype & 0xFF) == ARM64E:
        arch = "arm64e"
    uuid, vmaddr, at = None, 0, base + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[at:at + 8])
        if cmd == 0x1B:  # LC_UUID
            raw = data[at + 8:at + 24].hex().upper()
            uuid = f"{raw[:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:]}"
        elif cmd == 0x19 and data[at + 8:at + 24].rstrip(b"\0") == b"__TEXT":  # LC_SEGMENT_64
            vmaddr = struct.unpack("<Q", data[at + 24:at + 32])[0]
        at += size
    return [(arch, uuid, vmaddr)] if uuid else []


def index_dsyms(roots):
    """{UUID: (DWARF file, arch, __TEXT vmaddr)} for every dSYM under `roots`."""
    found = {}
    for root in roots:
        for dwarf in pathlib.Path(root).rglob("*.dSYM/Contents/Resources/DWARF/*"):
            if not dwarf.is_file():
                continue
            try:
                for arch, uuid, vmaddr in macho_slices(dwarf):
                    found[uuid] = (str(dwarf), arch, vmaddr)
            except (OSError, struct.error):
                continue
    return found


# MARK: Symbolizers


def which(*names):
    for name in names:
        if shutil.which(name):
            return [name]
    if shutil.which("xcrun"):
        for name in names:
            if subprocess.run(["xcrun", "--find", name], capture_output=True).returncode == 0:
                return ["xcrun", name]
    return None


def demangler():
    return which("swift-demangle")


def symbolize(dwarf, arch, vmaddr, offsets, tool):
    """{offset: [lines]} for one dSYM slice; inlined frames come first, as in a crash log."""
    addresses = [vmaddr + offset for offset in offsets]
    hexes = [hex(a) for a in addresses]
    if tool[-1] == "atos":
        out = subprocess.run(tool + ["-o", dwarf, "-arch", arch, "-l", hex(vmaddr), "-i"] + hexes,
                             capture_output=True, text=True, check=True).stdout
        # With -i, each address prints its inlined frames, then a blank line.
        groups, current = [], []
        for line in out.splitlines():
            if line.strip():
                current.append(line.strip())
            else:
                groups.append(current)
                current = []
        if current:
            groups.append(current)
        if len(groups) != len(offsets):  # an atos without blank separators: one line each
            groups = [[line.strip()] for line in out.splitlines() if line.strip()]
        return dict(zip(offsets, groups))
    out = subprocess.run(tool + ["--obj=" + dwarf, "--default-arch=" + arch, "--inlining", "--demangle",
                                 "--functions=linkage", "--output-style=JSON"] + hexes,
                         capture_output=True, text=True, check=True).stdout
    # Addresses on the command line: one JSON array of results, in order.
    entries = json.loads(out)
    if isinstance(entries, dict):
        entries = [entries]
    names = []
    results = {}
    for offset, entry in zip(offsets, entries):
        frames = entry.get("Symbol", [])
        results[offset] = frames
        names += [frame.get("FunctionName", "") for frame in frames]
    pretty = demangle(names)
    lines = {}
    for offset, frames in results.items():
        lines[offset] = []
        for frame in frames:
            name = pretty.get(frame.get("FunctionName", ""), frame.get("FunctionName", "")) or "??"
            where = f"{os.path.basename(frame['FileName'])}:{frame['Line']}" if frame.get("FileName") else ""
            lines[offset].append(f"{name} ({where})" if where else name)
    return lines


def demangle(names):
    tool = demangler()
    mangled = sorted({name for name in names if name.startswith(("$s", "_$s", "$S", "_T"))})
    if tool is None or not mangled:
        return {}
    out = subprocess.run(tool + ["--simplified", "--compact"], input="\n".join(mangled) + "\n",
                         capture_output=True, text=True).stdout.splitlines()
    return dict(zip(mangled, out)) if len(out) == len(mangled) else {}


# MARK: Reports


def render(report, dsyms, tool):
    binaries = report["binaries"]
    head = f"{report['kind']}  HerdrUp {report['version']} ({report['build']})  {report['device']}  {report['os']}"
    lines = [head]
    exception = report.get("exception")
    if exception:
        lines.append("exception: " + ", ".join(f"{k} {exception[k]}" for k in ("type", "code", "signal") if k in exception))
    if "termination" in report:
        lines.append("termination: " + report["termination"])
    if "hangSeconds" in report:
        lines.append(f"hang: {report['hangSeconds']} s")
    if report.get("truncated"):
        lines.append("(truncated by the app to fit the relay's cap)")

    # One symbolizer call per binary.
    wanted = {}
    for stack in report["stacks"]:
        for binary, offset in stack["frames"]:
            wanted.setdefault(binary, set()).add(offset)
    symbols, missing = {}, set()
    for binary, offsets in wanted.items():
        uuid = binaries[binary]["uuid"]
        match = dsyms.get(uuid)
        if match is None or tool is None:
            missing.add(binary)
            continue
        dwarf, arch, vmaddr = match
        symbols[binary] = symbolize(dwarf, arch, vmaddr, sorted(offsets), tool)

    width = max([len(b["name"]) for b in binaries] + [6])
    for number, stack in enumerate(report["stacks"]):
        lines.append("")
        lines.append(f"Stack {number}" + ("  (crashed / hung thread)" if stack["attributed"] else ""))
        for depth, (binary, offset) in enumerate(stack["frames"]):
            name = binaries[binary]["name"]
            resolved = symbols.get(binary, {}).get(offset)
            text = "; ".join(resolved) if resolved else f"{name} + {offset}"
            lines.append(f"{depth:<4}{name:<{width}}  0x{offset:08x}  {text}")
    ours = sorted({binaries[b]["name"] + " " + binaries[b]["uuid"] for b in missing
                   if binaries[b]["name"].startswith("Herdr")})
    if ours:
        lines += ["", "No dSYM for: " + ", ".join(ours)]
    return "\n".join(lines) + "\n"


def admin_get(relay, path, token):
    request = urllib.request.Request(relay + path, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def fetch_reports(relay, prefix, token, out):
    keys, cursor = [], None
    while True:
        query = {"prefix": prefix} | ({"cursor": cursor} if cursor else {})
        page = json.loads(admin_get(relay, "/v1/crash/reports?" + urllib.parse.urlencode(query), token))
        keys += [entry["key"] for entry in page["keys"]]
        cursor = page.get("cursor")
        if not cursor:
            break
    files = []
    for key in keys:
        path = out / "reports" / (key.replace("/", "_"))
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            path.write_bytes(admin_get(relay, "/v1/crash/reports/" + urllib.parse.quote(key, safe="/"), token))
        files.append(path)
    return files


def fetch_dsyms(build, out, repo):
    """Unzips the TestFlight artifact dSYMs-<build> into <out>/dsyms/<build>; the directory."""
    target = out / "dsyms" / build
    if target.exists():
        return target
    listing = subprocess.run(["gh", "api", f"repos/{repo}/actions/artifacts?name=dSYMs-{build}&per_page=1"],
                             capture_output=True, text=True)
    artifacts = json.loads(listing.stdout or "{}").get("artifacts", []) if listing.returncode == 0 else []
    if not artifacts or artifacts[0].get("expired"):
        print(f"no dSYMs-{build} artifact in {repo}", file=sys.stderr)
        return None
    archive = subprocess.run(["gh", "api", f"repos/{repo}/actions/artifacts/{artifacts[0]['id']}/zip"],
                             capture_output=True, check=True).stdout
    target.mkdir(parents=True)
    zipfile.ZipFile(io.BytesIO(archive)).extractall(target)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", nargs="+", type=pathlib.Path)
    parser.add_argument("--relay", default=RELAY)
    parser.add_argument("--prefix", default="v1/" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d") + "/")
    parser.add_argument("--dsyms", nargs="+", type=pathlib.Path)
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--out", type=pathlib.Path, default=pathlib.Path("crash-reports"))
    parser.add_argument("--symbolizer", help="atos or llvm-symbolizer (default: atos if present)")
    args = parser.parse_args()

    tool = which(args.symbolizer) if args.symbolizer else (
        which("atos") or which("llvm-symbolizer", *[f"llvm-symbolizer-{v}" for v in range(30, 12, -1)]))
    if tool is None:
        print("no atos or llvm-symbolizer: frames stay binary + offset", file=sys.stderr)

    args.out.mkdir(parents=True, exist_ok=True)
    if args.report:
        files = args.report
    else:
        token = os.environ.get("CRASH_ADMIN_TOKEN")
        if not token:
            parser.error("set CRASH_ADMIN_TOKEN to read reports from the relay, or pass --report")
        files = fetch_reports(args.relay.rstrip("/"), args.prefix, token, args.out)

    reports = [(path, json.loads(pathlib.Path(path).read_text())) for path in files]
    roots = list(args.dsyms or [])
    if not args.dsyms:
        for build in sorted({report["build"] for _, report in reports}):
            fetched = fetch_dsyms(build, args.out, args.repo)
            if fetched:
                roots.append(fetched)
    dsyms = index_dsyms(roots)

    for path, report in reports:
        text = render(report, dsyms, tool)
        (args.out / (pathlib.Path(path).stem + ".txt")).write_text(text)
        print(f"== {path}\n{text}")


if __name__ == "__main__":
    main()
