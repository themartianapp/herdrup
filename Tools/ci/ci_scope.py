#!/usr/bin/env python3
"""Decides whether a pull request needs the simulator UI matrix (the macserve shards in
.macserve.json; ci.yml's `scope` job records the answer on every PR).

The matrix is skipped only when every changed file is one of:

- documentation: anything under docs/, any Markdown file outside the directories the app
  or its packages build from (BUILD_DIRS), LICENSE, the top-level .gitignore, or
  .github/ISSUE_TEMPLATE/;
- a part of the repository the app build never reads (NO_UI_PREFIXES): the Cloudflare
  Workers GuestRelay/ and AccountService/ (their tests run in ci.yml's Linux jobs), the
  crash symbolication tools in Tools/crash/, and the GitHub workflows in .github/workflows/.
  The one exception is ci.yml, whose `scope` job runs this script: a ci.yml change skips
  the matrix only when every line its diff hunks change is inside one of its other jobs,
  or is a whole-line comment outside every job (the file's header); never a line of the
  `scope` job, nor a setting outside every job (triggers, concurrency, the `jobs:` key);
- project.yml, where every changed line changes only the value of an existing
  MARKETING_VERSION or CURRENT_PROJECT_VERSION setting. This reads the diff hunks, so a
  version bump that also touches any other line of project.yml runs the matrix.

A file renamed or copied between two such paths (both sides docs or NO_UI_PREFIXES, never
ci.yml or project.yml) skips too. Everything else runs it: any other path (this script
included), a rename or copy with either side elsewhere, a mode change, an added or deleted
project.yml or ci.yml, and a range git cannot resolve. Markdown under BUILD_DIRS is a
build input, not docs: xcodegen copies whatever is not code under App/ and HerdrUITests/
into the bundles, and SwiftTerm's .docc catalog belongs to its package.

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
DOCS_FILES = {"LICENSE", ".gitignore"}
DOCS_PREFIXES = ("docs/", ".github/ISSUE_TEMPLATE/")
# Paths project.yml, Package.swift and the build never read; test_ci_scope.py fails if
# project.yml or Package.swift names one. Owner's decision, 2026-11-19.
NO_UI_PREFIXES = ("AccountService/", "GuestRelay/", "Tools/crash/", ".github/workflows/")
CI_WORKFLOW = ".github/workflows/ci.yml"
SCOPE_JOB = "scope"
PROJECT_FILE = "project.yml"
ZERO_SHA = "0" * 40

# One `KEY: value` line of project.yml. The value must look like a version, quoted or not,
# so a change to `$(MARKETING_VERSION)` or to anything after the value is not a bump.
VERSION_LINE = re.compile(
    r'^(?P<indent>[ ]*)(?P<key>MARKETING_VERSION|CURRENT_PROJECT_VERSION):[ ]*'
    r'(?P<quote>"?)[0-9]+(?:\.[0-9]+)*(?P=quote)[ ]*$'
)
# A job's key under `jobs:` in a workflow file, at two spaces as ci.yml writes them.
JOB_KEY = re.compile(r"^  (?P<name>[A-Za-z_][A-Za-z0-9_-]*):[ ]*(?:#.*)?$")
HUNK = re.compile(r"^@@ -(?P<old>\d+)(?:,(?P<old_count>\d+))? \+(?P<new>\d+)(?:,(?P<new_count>\d+))? @@")


def is_no_ui_path(path: str) -> bool:
    """True for a path whose change alone cannot affect the UI matrix. Never ci.yml or
    project.yml: those skip only on what their diff hunks change (ui_reason)."""
    if path == CI_WORKFLOW:
        return False
    if path in DOCS_FILES or path.startswith(DOCS_PREFIXES + NO_UI_PREFIXES):
        return True
    return path.endswith(".md") and not path.startswith(BUILD_DIRS)


def job_of_lines(text: str) -> list[str | None]:
    """For each line of a workflow file (index 0 is line 1), the job under `jobs:` it
    belongs to, or None for a line outside every job. Comment lines above a job belong to
    the job before them, or to none before the first."""
    owners: list[str | None] = []
    in_jobs = False
    job: str | None = None
    for line in text.splitlines():
        if line and not line[0].isspace() and not line.startswith("#"):
            in_jobs = line.rstrip() == "jobs:"
            job = None
            owners.append(None)
            continue
        match = JOB_KEY.match(line) if in_jobs else None
        if match:
            job = match["name"]
        owners.append(job)
    return owners


def changed_line_numbers(patch: str) -> tuple[list[int], list[int]] | None:
    """(removed line numbers in the old file, added line numbers in the new file) of a
    `git diff -U0` patch of one file, or None when it is not a plain content change."""
    removed: list[int] = []
    added: list[int] = []
    in_header = True
    old = new = 0
    for line in patch.splitlines():
        hunk = HUNK.match(line)
        if hunk:
            old, new = int(hunk["old"]), int(hunk["new"])
            in_header = False
        elif in_header:
            if not line.startswith(("diff --git ", "index ", "--- a/", "+++ b/")):
                return None
        elif line.startswith("-"):
            removed.append(old)
            old += 1
        elif line.startswith("+"):
            added.append(new)
            new += 1
        else:
            return None
    if in_header:
        return None
    return removed, added


def scope_safe_workflow_change(old: str, new: str, patch: str) -> bool:
    """True when every line a -U0 patch of ci.yml removes (in `old`) or adds (in `new`) is
    inside a job other than SCOPE_JOB, or is a whole-line comment outside every job."""
    lines = changed_line_numbers(patch)
    if lines is None:
        return False
    removed, added = lines
    if not removed and not added:
        return False
    for text, numbers in ((old, removed), (new, added)):
        rows = text.splitlines()
        owners = job_of_lines(text)
        for number in numbers:
            if not 1 <= number <= len(owners):
                return False
            owner, row = owners[number - 1], rows[number - 1]
            if owner == SCOPE_JOB:
                return False
            if owner is None and not row.lstrip().startswith("#"):
                return False
    return True


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
            old_path, path = fields[i + 1], fields[i + 2]
            i += 3
            if is_no_ui_path(old_path) and is_no_ui_path(path):
                continue
            return f"{old_path} renamed or copied to {path}"
        path = fields[i + 1]
        i += 2
        if is_no_ui_path(path):
            continue
        if path in (PROJECT_FILE, CI_WORKFLOW) and code == "M":
            patch = git(
                "diff", "--no-ext-diff", "--no-color", "--no-textconv", "-U0",
                "--src-prefix=a/", "--dst-prefix=b/", changes, "--", path,
            )
            if path == PROJECT_FILE:
                if patch is not None and is_version_only_patch(patch):
                    continue
                return f"{PROJECT_FILE} changes more than MARKETING_VERSION/CURRENT_PROJECT_VERSION values"
            merge_base = (git("merge-base", base, head) or "").strip()
            old = git("show", f"{merge_base}:{CI_WORKFLOW}") if merge_base else None
            new = git("show", f"{head}:{CI_WORKFLOW}")
            if None not in (patch, old, new) and scope_safe_workflow_change(old, new, patch):
                continue
            return f"{CI_WORKFLOW} changes the {SCOPE_JOB} job or a setting outside its jobs"
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
        "UI matrix skipped: only docs, version numbers or files the app build never reads changed"
        if reason is None
        else f"UI matrix needed: {reason}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
