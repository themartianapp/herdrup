#!/usr/bin/env python3
"""Decides whether a pull request needs the simulator UI matrix (the macserve shards in
.macserve.json; ci.yml's `scope` job records the answer on every PR).

The matrix is skipped only when every changed file is one of:

- documentation: anything under docs/, any Markdown file outside the directories the app
  or its packages build from (BUILD_DIRS), LICENSE, or .github/ISSUE_TEMPLATE/;
- project.yml, where every changed line changes only the value of an existing
  MARKETING_VERSION or CURRENT_PROJECT_VERSION setting. This reads the diff hunks, so a
  version bump that also touches any other line of project.yml runs the matrix.

Everything else runs it: any other path (this script and ci.yml included), a renamed or
copied file, a mode change, an added or deleted project.yml, and a range git cannot
resolve. Markdown under BUILD_DIRS is a build input, not docs: xcodegen copies whatever
is not code under App/ and HerdrUITests/ into the bundles, and SwiftTerm's .docc catalog
belongs to its package.

Prints `ui=true` or `ui=false` for $GITHUB_OUTPUT and the reason on stderr.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys

# Top-level directories that project.yml or Package.swift compile or copy into a product.
# test_ci_scope.py fails if project.yml names a source directory missing from this list.
BUILD_DIRS = (
    "App/",
    "AskPush/",
    "HerdrFontTests/",
    "HerdrNotificationService/",
    "HerdrShareExtension/",
    "HerdrUITests/",
    "HerdrWidgets/",
    "PrivacyManifests/",
    "Shared/",
    "Sources/",
    "Tests/",
    "Vendor/",
)
DOCS_FILES = {"LICENSE"}
DOCS_PREFIXES = ("docs/", ".github/ISSUE_TEMPLATE/")
PROJECT_FILE = "project.yml"
ZERO_SHA = "0" * 40

# One `KEY: value` line of project.yml. The value must look like a version, quoted or not,
# so a change to `$(MARKETING_VERSION)` or to anything after the value is not a bump.
VERSION_LINE = re.compile(
    r'^(?P<indent>[ ]*)(?P<key>MARKETING_VERSION|CURRENT_PROJECT_VERSION):[ ]*'
    r'(?P<quote>"?)[0-9]+(?:\.[0-9]+)*(?P=quote)[ ]*$'
)


def is_docs_path(path: str) -> bool:
    if path in DOCS_FILES or path.startswith(DOCS_PREFIXES):
        return True
    return path.endswith(".md") and not path.startswith(BUILD_DIRS)


def is_version_only_patch(patch: str) -> bool:
    """True when a `git diff -U0` patch of project.yml only changes version values.

    Within each hunk the removed and added lines must pair up one to one: the same setting
    at the same indentation, with only the version value changed. A hunk that adds or drops
    a setting, or touches any other line, is not a version bump.
    """
    removed: list[str] = []
    added: list[str] = []
    hunks = 0
    in_header = True

    def hunk_is_bump() -> bool:
        if len(removed) != len(added):
            return False
        for old, new in zip(removed, added):
            old_match, new_match = VERSION_LINE.match(old), VERSION_LINE.match(new)
            if old_match is None or new_match is None:
                return False
            if (old_match["indent"], old_match["key"]) != (new_match["indent"], new_match["key"]):
                return False
        return True

    for line in patch.splitlines():
        if line.startswith("@@"):
            if hunks and not hunk_is_bump():
                return False
            removed.clear()
            added.clear()
            hunks += 1
            in_header = False
        elif in_header:
            # Only a plain content change is allowed: a mode change, rename, new or deleted
            # file, or binary patch adds header lines other than these.
            if not line.startswith(("diff --git ", "index ", "--- a/", "+++ b/")):
                return False
        elif line.startswith("-"):
            removed.append(line[1:])
        elif line.startswith("+"):
            added.append(line[1:])
        else:
            # "\ No newline at end of file", or a context line -U0 should not produce.
            return False
    return hunks > 0 and hunk_is_bump()


def git(*args: str) -> str | None:
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def ui_reason(base: str, head: str) -> str | None:
    """None when the change between `base` and `head` cannot affect the UI matrix,
    otherwise why it needs it."""
    if not base or not head or base == ZERO_SHA:
        return "no base commit to compare against"
    changes = f"{base}...{head}"
    status = git("diff", "--name-status", "-z", "--find-renames", "--find-copies", changes)
    if status is None:
        return f"git cannot resolve {changes}"
    fields = status.split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    if not fields:
        return "no changed files"
    i = 0
    while i < len(fields):
        code = fields[i]
        if code[:1] in ("R", "C"):
            return f"{fields[i + 1]} renamed or copied to {fields[i + 2]}"
        path = fields[i + 1]
        i += 2
        if is_docs_path(path):
            continue
        if path == PROJECT_FILE and code == "M":
            patch = git(
                "diff", "--no-ext-diff", "--no-color", "--no-textconv", "-U0",
                "--src-prefix=a/", "--dst-prefix=b/", changes, "--", PROJECT_FILE,
            )
            if patch is not None and is_version_only_patch(patch):
                continue
            return f"{PROJECT_FILE} changes more than MARKETING_VERSION/CURRENT_PROJECT_VERSION values"
        return f"{path} ({code})"
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("base", help="PR base commit")
    parser.add_argument("head", help="PR head commit")
    args = parser.parse_args(argv)
    reason = ui_reason(args.base, args.head)
    print(f"ui={'false' if reason is None else 'true'}")
    print(
        "UI matrix skipped: only docs or version numbers changed"
        if reason is None
        else f"UI matrix needed: {reason}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
