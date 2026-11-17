#!/usr/bin/env python3
"""Split App/HerdrApp.swift into focused files, mechanically and re-runnably.

The split moves whole top-level declarations (types, extensions, free functions,
`#Preview`s) out of App/HerdrApp.swift into the files listed in GROUPS. A
declaration is matched by its kind and name (`struct RootView`, `private extension
View`), never by line number, so the script can be rerun on any recent main, after
other PRs have edited the file. Each declaration keeps everything above it since
the previous declaration (doc comments, attributes, free-standing comments). Each
new file starts with HerdrApp.swift's own import block. A declaration that sat in a
top-level `#if DEBUG` block is wrapped in `#if DEBUG` / `#endif` in its new file.

No code changes, with the access widenings in WIDEN as the one exception (a
file-private declaration that two of the new files use; listed, checked).

The script fails loudly, writing nothing, when:
  - a top-level declaration in HerdrApp.swift is not in GROUPS, or is in it twice;
  - a target file already exists and would receive declarations;
  - a private/fileprivate name would be used from a file other than its own;
  - the result does not account for every original line exactly once
    (see check_split.py, which runs on the result before anything is written).

Rerunning it on a tree that is already split is a no-op: HerdrApp.swift then holds
only the entry point, which stays where it is.

Usage (from the repo root, or pass --root):
  Tools/refactor/split_herdrapp.py            # split, writing the files
  Tools/refactor/split_herdrapp.py --dry-run  # everything but the writes
  Tools/refactor/split_herdrapp.py --map      # print the declaration map (markdown)
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import check_split  # noqa: E402  (sibling module)

SOURCE = "App/HerdrApp.swift"

# Output file -> declaration keys, in the order of the declaration map
# (run with --map to list the keys of the current HerdrApp.swift). Within a file,
# declarations keep their original order, whatever the order here.
GROUPS: dict[str, list[str]] = {
    # App entry and scene: stays in HerdrApp.swift.
    "App/HerdrApp.swift": [
        "struct HerdrApp",
    ],
    # Root view: launch, scene phase, mock routing (mockView), live content.
    "App/RootView.swift": [
        "struct RootView",
    ],
    # Connect / first-run screen, and the setup commands it shares with the home list.
    "App/ConnectView.swift": [
        "enum HerdrSetup",
        "struct ConnectRowButtonStyle",
        "struct ConnectView",
    ],
    # Sheets the home list presents: new agent (and its folder browser), rename, shortcuts.
    "App/HomeSheets.swift": [
        "struct NewAgentView",
        "struct FolderBrowser",
        "struct ShortcutsSheet",
        "struct RenameSheet",
    ],
    # Machines / agent roster home list: the split view, sidebar, roster and detail column.
    "App/TerminalHomeView.swift": [
        "class AgentRosterPendingBuffer",
        "class AgentRosterLoadGateBuffer",
        "class AgentRosterScrollBuffer",
        "class AgentRosterLiveEventsBuffer",
        "struct ScrollActivityObserver",
        "struct SidebarTabBarMaterial",
        "struct TerminalHomeView",
    ],
    # Agent page: the composer's UIKit text field.
    "App/ComposerTextField.swift": [
        "struct ComposerTextField",
    ],
    # Agent page: the terminal pane and its edge swipe back.
    "App/TerminalPaneContent.swift": [
        "struct EdgeSwipeBack",
        "struct TerminalPaneContent",
    ],
    # Settings.
    "App/SettingsView.swift": [
        "enum SettingsSection",
        "enum SettingsMode",  # added by #669 (guest Settings); absent on main until it lands
        "struct SettingsBackButton",
        "struct DetailSwipeBack",
        "struct SettingsIndexContent",
        "struct SettingsView",
    ],
    # View helpers: the reading column and the row/group shells.
    "App/LayoutHelpers.swift": [
        "struct ReadableColumn",
        "private extension View",
        "extension View",
    ],
    # DEBUG: mock and UI-test switches (HERDR_SCREENSHOT_MOCK / HERDR_MOCK_*) and harness views.
    "App/ScreenshotMock.swift": [
        "struct GramScreenshotHarness",
        "struct PagingTestHarness",
        "struct HtmlPreviewHarness",
        "enum ScreenshotMock",
        "struct ForgetCapableMockTransport",
        "struct SessionsMockHome",
        "struct SessionsMockTransport",
    ],
    # DEBUG: the mock transport and its recorders.
    "App/MockTransport.swift": [
        "struct MockTransport",
        "class GramPostRecorder",
        "class GramOwnerReads",
        "class GramGetFileRecorder",
        "class GramPagingMock",
    ],
    # DEBUG: stress and paging drivers/probes used by UI tests.
    "App/MockDrivers.swift": [
        "struct RosterStressArmControl",
        "class RosterStressDriver",
        "class KeyframeHistoryDriver",
        "struct KeyframeHistoryReadProbe",
        "class HistoryPagingDriver",
        "struct HistoryPagingProbe",
        "class CCScrollDriver",
    ],
}

# Access widenings: declaration key -> (old head prefix, new head prefix). Only where a
# file-private declaration is used from two of the new files. Each is checked.
WIDEN: dict[str, tuple[str, str]] = {
    # rowShell / settingsRowShell / settingsGroup: used by ConnectView, NewAgentView and
    # SettingsView, three files. Widened to internal; no other declaration in the module
    # has these names.
    "private extension View": ("private extension View", "extension View"),
}

TOP_LEVEL_IF = re.compile(r"^#(if|elseif|else|endif)\b(.*)$")


# --------------------------------------------------------------------------- lexer


@dataclass
class LineInfo:
    depth_start: int        # bracket depth ({[( ) at the start of the line, top frame
    top_start: bool         # the line starts in plain code (not in a string/comment)
    has_code: bool          # the line holds a code character (not only whitespace/comments)
    opens_brace: bool       # a `{` at the top frame on this line
    depth_end: int = 0
    code: str = ""          # the line with comments and string contents blanked


def lex_lines(text: str) -> list[LineInfo]:
    """Per-line bracket depth, aware of comments, (raw, multi-line) strings,
    string interpolation and `#if/#else/#endif` branches (only the first branch
    counts, and every branch must leave the same depth)."""
    lines = text.split("\n")
    infos: list[LineInfo] = []
    # Frames: ("code", parens) top or interpolation; ("str", hashes, multiline).
    stack: list[list] = [["code", 0]]
    depth = 0
    block = 0               # nested /* */ level
    if_stack: list[list[int]] = []  # [depth_at_if, depth_after_first_branch or -1]
    for raw in lines:
        top = len(stack) == 1 and block == 0
        info = LineInfo(depth, top, False, False)
        stripped = raw.strip()
        m = TOP_LEVEL_IF.match(stripped) if top else None
        if m:
            kw = m.group(1)
            info.has_code = True
            if kw == "if":
                if_stack.append([depth, -1])
            elif kw in ("elseif", "else"):
                if not if_stack:
                    raise SplitError(f"#{kw} without #if")
                frame = if_stack[-1]
                if frame[1] == -1:
                    frame[1] = depth
                elif frame[1] != depth:
                    raise SplitError("#if branches leave different bracket depths")
                depth = frame[0]
            else:
                if not if_stack:
                    raise SplitError("#endif without #if")
                d0, d1 = if_stack.pop()
                if d1 != -1:
                    if d1 != depth:
                        raise SplitError("#if branches leave different bracket depths")
                    depth = d1
            info.depth_end = depth
            info.code = raw
            infos.append(info)
            continue
        i, n = 0, len(raw)
        buf = [" "] * n
        while i < n:
            c = raw[i]
            if block:
                if raw.startswith("/*", i):
                    block += 1
                    i += 2
                elif raw.startswith("*/", i):
                    block -= 1
                    i += 2
                else:
                    i += 1
                continue
            fr = stack[-1]
            if fr[0] == "str":
                hashes, multi = fr[1], fr[2]
                if c == "\\" and raw.startswith("#" * hashes, i + 1):
                    j = i + 1 + hashes
                    if j < n and raw[j] == "(":
                        stack.append(["code", 0])
                        i = j + 1
                    else:
                        i = j + 1
                    continue
                close = ('"""' if multi else '"') + "#" * hashes
                if raw.startswith(close, i):
                    stack.pop()
                    i += len(close)
                    info.has_code = True
                    continue
                i += 1
                continue
            # code
            if c.isspace():
                i += 1
                continue
            if raw.startswith("//", i):
                break
            if raw.startswith("/*", i):
                block = 1
                i += 2
                continue
            info.has_code = True
            if c == "#" or c == '"':
                j = i
                while j < n and raw[j] == "#":
                    j += 1
                if j < n and raw[j] == '"':
                    hashes = j - i
                    if raw.startswith('"""', j):
                        stack.append(["str", hashes, True])
                        i = j + 3
                    else:
                        stack.append(["str", hashes, False])
                        i = j + 1
                    continue
                buf[i:j] = raw[i:j]
                i = j if j > i else i + 1
                continue
            buf[i] = c
            if c in "([{":
                if len(stack) == 1:
                    depth += 1
                    if c == "{":
                        info.opens_brace = True
                else:
                    fr[1] += 1
            elif c in ")]}":
                if len(stack) == 1:
                    depth -= 1
                    if depth < 0:
                        raise SplitError("unbalanced brackets")
                else:
                    if c == ")" and fr[1] == 0:
                        stack.pop()  # end of interpolation
                    else:
                        fr[1] -= 1
            i += 1
        # A single-line string cannot cross a line end (multi-line ones can).
        if stack[-1][0] == "str" and not stack[-1][2]:
            raise SplitError(f"unterminated string literal: {raw!r}")
        info.depth_end = depth
        info.code = "".join(buf)
        infos.append(info)
    if depth != 0 or len(stack) != 1 or block or if_stack:
        raise SplitError("file ends inside a block, string, comment or #if")
    return infos


# --------------------------------------------------------------------------- parse

DECL_KINDS = (
    "struct", "class", "enum", "actor", "protocol", "extension", "func",
    "typealias", "let", "var", "macro", "precedencegroup", "operator",
)
MODIFIERS = {
    "private", "fileprivate", "internal", "public", "open", "package", "final",
    "static", "nonisolated", "indirect", "dynamic", "prefix", "postfix", "infix",
    "convenience", "required", "lazy", "weak", "unowned", "mutating", "nonmutating",
}
ACCESS = ("private", "fileprivate", "internal", "public", "open", "package")
BRACE_KINDS = {"struct", "class", "enum", "actor", "protocol", "extension", "func",
               "macro", "precedencegroup", "#Preview"}


class SplitError(Exception):
    pass


@dataclass
class Decl:
    key: str
    kind: str
    name: str
    access: str             # "", "private", "fileprivate", ...
    condition: str | None   # e.g. "DEBUG" when inside a top-level `#if DEBUG`
    trivia_start: int       # first line (0-based) of the leading comments/blank lines
    decl_start: int         # first line of the declaration itself (attributes included)
    end: int                # last line, inclusive (trailing comments included)
    lines: list[str] = field(default_factory=list)  # trivia + declaration, blank-trimmed
    head: int = 0           # index in `lines` of the declaration's first line

    def text(self) -> str:
        return "\n".join(self.lines)


@dataclass
class Parsed:
    header: list[str]       # the import block (and any comments among the imports)
    decls: list[Decl]
    lines: list[str]


def strip_comments_and_strings(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)
    s = re.sub(r"//[^\n]*", " ", s)
    return s


def parse_head(head: str) -> tuple[str, str, str]:
    """(kind, name, access) from a declaration's first lines (attributes included)."""
    s = strip_comments_and_strings(head)
    pos = 0
    access = ""
    words: list[str] = []
    while True:
        s2 = s[pos:].lstrip()
        pos = len(s) - len(s2)
        if s2.startswith("@"):
            m = re.match(r"@[\w.]+", s2)
            pos += m.end()
            rest = s[pos:]
            if rest.startswith("("):
                d = 0
                for k, ch in enumerate(rest):
                    d += ch == "("
                    d -= ch == ")"
                    if d == 0:
                        pos += k + 1
                        break
            continue
        if s2.startswith("#Preview"):
            m = re.match(r'#Preview\s*(?:\(\s*"([^"]*)")?', s2)
            return "#Preview", m.group(1) or "", access
        m = re.match(r"(\w+)(\s*\(\s*set\s*\))?", s2)
        if not m:
            raise SplitError(f"cannot read declaration head: {head.splitlines()[0]!r}")
        w = m.group(1)
        pos += m.end()
        if w in MODIFIERS:
            if w in ACCESS and not m.group(2):
                access = w
            words.append(w)
            continue
        if w in DECL_KINDS:
            rest = s[pos:]
            if w == "extension":
                m2 = re.match(r"\s*([\w.]+(?:<[^>{]*>)?)\s*(:\s*[^{]*?)?\s*(where[^{]*)?\{", rest, re.S)
                if not m2:
                    raise SplitError(f"cannot read extension head: {head.splitlines()[0]!r}")
                name = m2.group(1)
                conf = (m2.group(2) or "").strip()
                if conf:
                    name += ": " + re.sub(r"\s+", " ", conf[1:].strip())
                return w, name, access
            m2 = re.match(r"\s*(`?[\w]+`?|[^\s(<{]+)", rest)
            return w, m2.group(1) if m2 else "", access
        raise SplitError(f"unknown top-level declaration: {head.splitlines()[0]!r}")


def make_key(kind: str, name: str, access: str) -> str:
    if kind == "extension":
        return f"{access + ' ' if access else ''}extension {name}"
    if kind == "#Preview":
        return f'#Preview "{name}"' if name else "#Preview"
    return f"{kind} {name}"


def parse(text: str) -> Parsed:
    if not text.endswith("\n"):
        text += "\n"
    lines = text[:-1].split("\n")
    infos = lex_lines(text[:-1])
    decls: list[Decl] = []
    header_end = -1          # last line of the import block
    trivia_start = 0
    condition: str | None = None
    i = 0
    seen: Counter[str] = Counter()

    def is_trivia(k: int) -> bool:
        return not infos[k].has_code

    while i < len(lines):
        info = infos[i]
        if not (info.top_start and info.depth_start == 0):
            raise SplitError(f"line {i + 1}: parser lost track of the top level")
        stripped = lines[i].strip()
        if is_trivia(i):
            i += 1
            continue
        if re.match(r"(@\w+\s+)*import\s", stripped):
            if decls:
                raise SplitError(f"line {i + 1}: import after the first declaration")
            header_end = i
            trivia_start = i + 1
            i += 1
            continue
        m = TOP_LEVEL_IF.match(stripped)
        if m:
            kw, cond = m.group(1), m.group(2).strip()
            if kw == "if":
                if condition is not None:
                    raise SplitError(f"line {i + 1}: nested top-level #if")
                condition = cond
                attach_trailing(decls, lines, trivia_start, i)
                trivia_start = i + 1
            elif kw == "endif":
                if condition is None:
                    raise SplitError(f"line {i + 1}: #endif without #if")
                attach_trailing(decls, lines, trivia_start, i, condition)
                condition = None
                trivia_start = i + 1
            else:
                raise SplitError(f"line {i + 1}: top-level #{kw} is not supported; map it by hand")
            i += 1
            continue
        # A declaration: read its head, then find its last line.
        head = "\n".join(lines[i:i + 12])
        kind, name, access = parse_head(head)
        j = i
        opened = False
        while True:
            if infos[j].opens_brace:
                opened = True
            done = infos[j].depth_end == 0 and (opened or kind not in BRACE_KINDS)
            if done:
                break
            j += 1
            if j >= len(lines):
                raise SplitError(f"line {i + 1}: {kind} {name} never ends")
        key = make_key(kind, name, access)
        seen[key] += 1
        if seen[key] > 1:
            key = f"{key} #{seen[key]}"
        decls.append(Decl(key, kind, name, access, condition, trivia_start, i, j))
        trivia_start = j + 1
        i = j + 1
    if condition is not None:
        raise SplitError("file ends inside a top-level #if")
    attach_trailing(decls, lines, trivia_start, len(lines))
    header = lines[: header_end + 1]
    for d in decls:
        lead = d.trivia_start
        while not lines[lead].strip():
            lead += 1
        d.lines = trim_blank(lines[lead: d.end + 1])
        d.head = d.decl_start - lead
    return Parsed(header, decls, lines)


def attach_trailing(decls, lines, start, stop, condition="__any__"):
    """Comments between the last declaration and an `#if`/`#endif`/end of file belong
    to that declaration (only if it is in the same #if block)."""
    body = trim_blank(lines[start:stop])
    if not body:
        return
    if not decls or (condition != "__any__" and decls[-1].condition != condition) or decls[-1].end + 1 != start:
        raise SplitError(f"line {start + 1}: comments that belong to no declaration")
    decls[-1].end = stop - 1


def trim_blank(block: list[str]) -> list[str]:
    a, b = 0, len(block)
    while a < b and not block[a].strip():
        a += 1
    while b > a and not block[b - 1].strip():
        b -= 1
    return block[a:b]


# --------------------------------------------------------------------------- split


def assignment(decls: list[Decl]) -> dict[str, str]:
    """Declaration key -> output file. Fails on unassigned or doubly assigned keys."""
    owner: dict[str, str] = {}
    dup: list[str] = []
    for f, keys in GROUPS.items():
        for k in keys:
            if k in owner:
                dup.append(f"{k} ({owner[k]} and {f})")
            owner[k] = f
    if dup:
        raise SplitError("assigned twice in GROUPS: " + "; ".join(dup))
    present = [d.key for d in decls]
    unassigned = [k for k in present if k not in owner]
    if unassigned:
        raise SplitError(
            "declarations in HerdrApp.swift that GROUPS does not assign (add each to a group):\n  "
            + "\n  ".join(unassigned))
    return owner


def widened(d: Decl) -> list[str]:
    if d.key not in WIDEN:
        return d.lines
    old, new = WIDEN[d.key]
    out = list(d.lines)
    if not out[d.head].startswith(old):
        raise SplitError(f"WIDEN: {d.key} does not start with {old!r}: {out[d.head]!r}")
    out[d.head] = new + out[d.head][len(old):]
    return out


def render(header: list[str], decls: list[Decl]) -> str:
    out: list[str] = list(header)
    cond: str | None = None
    for d in decls:
        if d.condition != cond:
            if cond is not None:
                out += ["#endif"]
            out += [""]
            if d.condition is not None:
                out += [f"#if {d.condition}"]
            cond = d.condition
        else:
            out += [""]
        out += widened(d)
    if cond is not None:
        out += ["#endif"]
    return "\n".join(out) + "\n"


def private_names(decls: list[Decl]) -> dict[str, list[str]]:
    """Declaration key -> names visible only in its file (after widening)."""
    res: dict[str, list[str]] = {}
    for d in decls:
        names: list[str] = []
        if d.access in ("private", "fileprivate") and d.key not in WIDEN:
            if d.kind == "extension":
                names += re.findall(r"^\s*(?:@\w+\s+)*(?:static\s+)?(?:func|var|let)\s+(\w+)", code_only(d.text()), re.M)
            else:
                names.append(d.name)
        names += re.findall(r"\bfileprivate\s+(?:static\s+|final\s+)*(?:func|var|let|struct|class|enum)\s+(\w+)", code_only(d.text()))
        if names:
            res[d.key] = sorted(set(names))
    return res


def code_only(text: str) -> str:
    """The text with comments and string literal contents blanked (interpolations kept)."""
    return "\n".join(info.code for info in lex_lines(text))


def access_violations(decls: list[Decl], owner: dict[str, str]) -> list[str]:
    bad = []
    priv = private_names(decls)
    code = {d.key: code_only(d.text()) for d in decls} if priv else {}
    for key, names in priv.items():
        for name in names:
            pat = re.compile(rf"\b{re.escape(name)}\b")
            for d in decls:
                if owner[d.key] != owner[key] and pat.search(code[d.key]):
                    bad.append(f"{name} (file-private in {key}, {owner[key]}) used by {d.key} ({owner[d.key]})")
    return bad


def plan(text: str) -> tuple[Parsed, dict[str, str], dict[str, str]]:
    """Parse and split: (parsed, owner map, {path: new content})."""
    parsed = parse(text)
    owner = assignment(parsed.decls)
    bad = access_violations(parsed.decls, owner)
    if bad:
        raise SplitError("file-private names used across files (keep together or WIDEN):\n  " + "\n  ".join(bad))
    files: dict[str, str] = {}
    for f in GROUPS:
        mine = [d for d in parsed.decls if owner[d.key] == f]
        if mine or f == SOURCE:
            files[f] = render(parsed.header, mine)
    return parsed, owner, files


def git_root(start: Path) -> Path:
    out = subprocess.run(["git", "-C", str(start), "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    return Path(out.stdout.strip()) if out.returncode == 0 else start


def print_map(parsed: Parsed, owner: dict[str, str] | None) -> None:
    names = {d.name.split(":")[0].split("<")[0]: d.key for d in parsed.decls if d.kind != "extension"}
    print("| Lines | Key | Access | #if | Size | Uses (top-level names in this file) | File |")
    print("|---|---|---|---|---|---|---|")
    for d in parsed.decls:
        body = code_only("\n".join(parsed.lines[d.decl_start: d.end + 1]))
        uses = sorted(n for n in names if names[n] != d.key and re.search(rf"\b{re.escape(n)}\b", body))
        print(f"| {d.decl_start + 1}-{d.end + 1} | `{d.key}` | {d.access or 'internal'} | "
              f"{d.condition or ''} | {d.end - d.trivia_start + 1} | {', '.join(uses)} | "
              f"{(owner or {}).get(d.key, '?')} |")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=None, help="repo root (default: git top level of cwd)")
    ap.add_argument("--dry-run", action="store_true", help="check everything, write nothing")
    ap.add_argument("--map", action="store_true", help="print the declaration map and exit")
    args = ap.parse_args(argv)
    root = args.root or git_root(Path.cwd())
    src = root / SOURCE
    text = src.read_text()
    try:
        if args.map:
            parsed = parse(text)
            try:
                owner = assignment(parsed.decls)
            except SplitError:
                owner = None
            print_map(parsed, owner)
            return 0
        parsed, owner, files = plan(text)
        present = {d.key for d in parsed.decls}
        missing = [k for keys in GROUPS.values() for k in keys if k not in present]
        moved = [d for d in parsed.decls if owner[d.key] != SOURCE]
        if not moved:
            print(f"{SOURCE}: nothing to move (already split).")
            return 0
        if missing:
            print("note: in GROUPS but not in HerdrApp.swift (not landed yet, or removed/renamed): "
                  + ", ".join(missing), file=sys.stderr)
        for f in files:
            if f != SOURCE and (root / f).exists():
                raise SplitError(f"{f} already exists; refusing to overwrite it")
        problems = check_split.check(text, files, {d.key: WIDEN[d.key] for d in parsed.decls if d.key in WIDEN})
        if problems:
            raise SplitError("check_split failed:\n  " + "\n  ".join(problems))
    except SplitError as e:
        print(f"split_herdrapp: {e}", file=sys.stderr)
        return 1
    for f, content in files.items():
        n = content.count("\n")
        k = sum(1 for d in parsed.decls if owner[d.key] == f)
        print(f"{f}: {n} lines, {k} declarations")
        if not args.dry_run:
            (root / f).write_text(content)
    if args.dry_run:
        print("dry run: nothing written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
