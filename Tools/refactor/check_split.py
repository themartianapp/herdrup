#!/usr/bin/env python3
"""Check that a split of App/HerdrApp.swift moved code and changed nothing.

Independent of split_herdrapp.py's parser: it compares normalized text.
  1. Lines: the multiset of non-blank lines (trailing whitespace stripped) of the
     original, without its import block and its top-level `#if DEBUG`/`#endif` lines,
     equals the same multiset over the new files (each without its import block and
     its top-level `#if`/`#endif` lines). Nothing lost, nothing duplicated. The access
     widenings listed by the splitter are the only lines allowed to differ.
  2. Order: each new file's lines appear in the original in the same order (a
     subsequence), so no declaration was reshuffled internally.
  3. Imports: every new file starts with the original's import block, verbatim.
  4. Parse (with --parse, or from the CLI): `swiftc -parse` accepts each file.

CLI, after a split in the working tree:
  Tools/refactor/check_split.py --base origin/main [--swiftc /opt/swift/usr/bin/swiftc]
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

SOURCE = "App/HerdrApp.swift"
IMPORT = re.compile(r"^(@\w+\s+)*import\s")
TOP_IF = re.compile(r"^#(if|endif)\b")


def import_block(lines: list[str]) -> list[str]:
    last = max((k for k, l in enumerate(lines) if IMPORT.match(l)), default=-1)
    return lines[: last + 1]


def body_lines(text: str) -> list[str]:
    lines = text.rstrip("\n").split("\n")
    head = len(import_block(lines))
    return [l.rstrip() for l in lines[head:] if l.strip() and not TOP_IF.match(l)]


def is_subsequence(needle: list[str], hay: list[str]) -> bool:
    it = iter(hay)
    return all(any(x == y for y in it) for x in needle)


def check(original: str, files: dict[str, str], widen: dict[str, tuple[str, str]]) -> list[str]:
    problems: list[str] = []
    orig_lines = original.rstrip("\n").split("\n")
    header = import_block(orig_lines)
    orig = body_lines(original)
    # Apply the declared widenings to the original: each rewrites the head of exactly one
    # top-level declaration (a column-0 line).
    for key, (old, new) in widen.items():
        head = re.compile(rf"{re.escape(old)}\b")
        hits = [k for k, l in enumerate(orig) if head.match(l)]
        if len(hits) != 1:
            problems.append(f"widening {key!r}: {len(hits)} top-level lines start with {old!r} (want 1)")
            continue
        orig[hits[0]] = new + orig[hits[0]][len(old):]
    new_all: list[str] = []
    for path, text in files.items():
        lines = text.rstrip("\n").split("\n")
        if lines[: len(header)] != header:
            problems.append(f"{path}: does not start with the original import block")
        body = body_lines(text)
        if not is_subsequence(body, orig):
            problems.append(f"{path}: lines are not in their original order")
        new_all += body
    a, b = Counter(orig), Counter(new_all)
    lost, dup = a - b, b - a
    for line, n in sorted(lost.items())[:20]:
        problems.append(f"lost x{n}: {line.strip()[:120]}")
    for line, n in sorted(dup.items())[:20]:
        problems.append(f"added/duplicated x{n}: {line.strip()[:120]}")
    if lost or dup:
        problems.append(f"{sum(lost.values())} lines lost, {sum(dup.values())} added")
    return problems


def swift_parse(files: dict[str, str], swiftc: str) -> list[str]:
    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        for path, text in files.items():
            p = Path(tmp) / Path(path).name
            p.write_text(text)
            r = subprocess.run([swiftc, "-parse", str(p)], capture_output=True, text=True)
            if r.returncode != 0:
                problems.append(f"{path}: swiftc -parse failed:\n{r.stderr.strip()[:2000]}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="origin/main", help="git revision holding the unsplit HerdrApp.swift")
    ap.add_argument("--root", type=Path, default=Path.cwd())
    ap.add_argument("--swiftc", default=shutil.which("swiftc") or "/opt/swift/usr/bin/swiftc")
    ap.add_argument("--no-parse", action="store_true")
    args = ap.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import split_herdrapp as sh

    original = subprocess.run(["git", "-C", str(args.root), "show", f"{args.base}:{SOURCE}"],
                              capture_output=True, text=True, check=True).stdout
    files = {f: (args.root / f).read_text() for f in sh.GROUPS if (args.root / f).exists()}
    problems = check(original, files, sh.WIDEN)
    if not args.no_parse:
        problems += swift_parse(files, args.swiftc)
    for p in problems:
        print(p)
    total = sum(t.count("\n") for t in files.values())
    print(f"{len(files)} files, {total} lines: " + ("FAIL" if problems else "OK"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
