#!/usr/bin/env python3
"""Reads result bundles for Tools/ci/ui-shard.sh: `xcrun xcresulttool get test-results tests
--path BUNDLE` JSON on stdin, unless a command names its input. A separate file, not
`python3 -c '…'` inside the shell script: a single
quote inside such a snippet ends the shell string (PR #649's first head failed every shard's
class check with "f-string: expecting a valid expression"), and Tools/ci/check.sh can compile
and test a file.

  xcresult-tests.py failed-tests
      Prints one -only-testing argument per failed Class/method test case. A runner that
      crashes while bootstrapping is recorded as a failed "Test Case" named like
      "HerdrUITests-Runner (21391) encountered an error" (run 40728450580); passed to
      xcodebuild it failed with "Unknown build action '(21391)'", so only Class/method
      identifiers are printed. Unreadable input prints nothing.

  xcresult-tests.py ran-none
      Exits 0 only when the bundle records no Class/method test case. Unreadable input exits
      1: a round that may have run a test is never treated as unstarted.

  xcresult-tests.py check-classes BUNDLE ROUND_RESULT CLASS...
      Exits 1 unless every CLASS executed a test. Only a round that ran tests and still
      skipped a listed class shows a stale name; a round that never started, or ran out of
      its budget (ROUND_RESULT timeout), says so instead.

  xcresult-tests.py infra-only BUNDLE
      Exits 0 when BUNDLE has failed test cases and every issue recorded against every one
      of them was raised by XCTest's UI automation itself, with one of the INFRASTRUCTURE
      descriptions, printing each issue with its verdict. Exits 1 when any issue is anything
      else (an assertion above all), when a failed case has no issue, and when the bundle's
      issue records cannot be read.

  xcresult-tests.py app-crashed ATTACHMENTS_DIR BUNDLE_ID
      Exits 0 when the exported attachments hold a crash report (.ips) of BUNDLE_ID.
"""
import glob
import json
import os
import re
import sqlite3
import sys

CASE = re.compile(r"\w+/\w+")

# Infrastructure is told by WHO raised the failure, not by what its text says. The result
# bundle records each issue's type: XCTAssert*, XCTFail and crashes are "Assertion Failure"
# (a test that fails "Critical process SpringBoard crashed" with XCTFail stays an assertion),
# while "UI Automation Failure" is raised by XCTest's automation when it cannot drive the
# app at all. That type is not in `xcresulttool get test-results` JSON, so it is read from the
# bundle's database.sqlite3 (TestIssues.issueType; Xcode 27.1 bundles from runs 42770272602,
# 42808627997 and 42815902188). Even then only these descriptions count: automation failures
# like "Neither element nor any descendant has keyboard focus" can be the app's fault. Each
# was followed by a passing rerun of the same tests on the same commit:
#  - a simulator system process (never the app under test) crashed mid-test: "Critical
#    process SpringBoard crashed" (run 42770272602 iPadResize: SpringBoard SIGBUS in
#    NSXPCEncoder), "Critical process runningboardd crashed";
#  - the app never got a process: "Application 'com.jerryfane.herdr' does not have a process
#    ID" from app.launch() after 153 s (42770272602 iPadGramColumn, no crash report of the
#    app), and the follow-on "Failed to get background assertion for target app with pid 0";
#  - XCTest could not kill the previous launch: "Failed to terminate com.jerryfane.herdr:N:
#    Failed to terminate com.jerryfane.herdr:0" (42273527812 and seven more).
AUTOMATION = "UI Automation Failure"
# Issue types that never fail a test.
NOT_FAILURES = {"Runtime Warning"}
INFRASTRUCTURE = [
    re.compile(r"^Critical process \S+ crashed"),
    re.compile(r"^Application '[\w.]+' does not have a process ID"),
    re.compile(r"^Failed to get background assertion for target app with pid 0\b"),
    re.compile(r"^Failed to terminate [\w.]+:\d+: Failed to terminate [\w.]+:0\b"),
]


def load():
    try:
        return json.load(sys.stdin)
    except ValueError:
        return None


def identifier(node):
    return node.get("nodeIdentifier", "").removesuffix("()")


def failed_tests(data):
    def walk(node, bundle):
        if node.get("nodeType") in ("UI test bundle", "Unit test bundle"):
            bundle = node.get("name")
        if node.get("nodeType") == "Test Case" and node.get("result") == "Failed" and bundle \
                and CASE.fullmatch(identifier(node)):
            print("-only-testing:%s/%s" % (bundle, identifier(node)))
        for child in node.get("children", []):
            walk(child, bundle)
    for node in (data or {}).get("testNodes", []):
        walk(node, None)
    return 0


def ran_none(data):
    if data is None:
        return 1
    def ran(node):
        if node.get("nodeType") == "Test Case" and CASE.fullmatch(identifier(node)):
            return True
        return any(ran(child) for child in node.get("children", []))
    return 1 if any(ran(node) for node in data.get("testNodes", [])) else 0


def check_classes(data, bundle, round_result, names):
    round_name = os.path.basename(bundle).removesuffix("-first.xcresult")
    listed = ", ".join(names)
    if data is None:
        print("::error::%s left no readable result bundle, so it cannot show that %s ran: "
              "the round failed before testing (see its error above)" % (round_name, listed))
        return 1
    ran = set()
    def walk(node, suite):
        if node.get("nodeType") == "Test Suite":
            suite = node.get("name")
        if node.get("nodeType") == "Test Case" and node.get("result") != "Skipped" and suite:
            ran.add(suite)
        for child in node.get("children", []):
            walk(child, suite)
    for node in data.get("testNodes", []):
        walk(node, None)
    missing = [name for name in names if name not in ran]
    if missing and not ran:
        print("::error::%s executed no test case, so it cannot show that %s ran: the round "
              "failed before testing (see its error above)" % (round_name, listed))
    elif missing and round_result == "timeout":
        print("::error::%s ran out of its budget before %s ran (see its error above)"
              % (round_name, ", ".join(missing)))
    else:
        for name in missing:
            print("::error::%s executed no tests in this round; the listed name no longer matches "
                  "a class, so that class falls through to the iphone-app catch-all round" % name)
    return 1 if missing else 0


def infra_only(bundle):
    """See the module doc. Reads the result bundle's own issue records."""
    database = os.path.join(bundle, "database.sqlite3")
    try:
        connection = sqlite3.connect("file:%s?mode=ro" % database, uri=True)
        rows = connection.execute(
            "SELECT tc.identifier, ti.issueType, ti.compactDescription"
            " FROM TestCaseRuns tcr JOIN TestCases tc ON tcr.testCase_fk = tc.rowid"
            " LEFT JOIN TestIssues ti ON ti.testCaseRun_fk = tcr.rowid"
            " WHERE tcr.result = 'Failure'").fetchall()
    except sqlite3.Error as error:
        print("TEST FAILURE: cannot read the issues of %s: %s" % (bundle, error))
        return 1
    failures = {}  # Class/method -> [(issue type, description)]
    for case, issue_type, description in rows:
        issues = failures.setdefault((case or "").removesuffix("()"), [])
        if issue_type is not None and issue_type not in NOT_FAILURES:
            issues.append((issue_type, description or ""))
    if not failures:
        return 1
    verdict = 0
    for case, issues in sorted(failures.items()):
        if not CASE.fullmatch(case) or not issues:
            print("TEST FAILURE %s: not a Class/method failure with a recorded issue" % case)
            verdict = 1
        for issue_type, description in issues:
            infra = issue_type == AUTOMATION and any(p.search(description) for p in INFRASTRUCTURE)
            print("%s %s: [%s] %s" % ("infrastructure" if infra else "TEST FAILURE", case, issue_type,
                                      description.replace("\n", " ")[:300]))
            if not infra:
                verdict = 1
    return verdict


def app_crashed(directory, bundle_id):
    for report in glob.glob(os.path.join(directory, "**", "*.ips"), recursive=True):
        try:
            with open(report, errors="replace") as source:
                header = json.loads(source.readline())
        except (OSError, ValueError):
            continue
        if header.get("bundleID") == bundle_id:
            print("crash report of %s: %s" % (bundle_id, report))
            return 0
    return 1


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "failed-tests" and len(sys.argv) == 2:
        sys.exit(failed_tests(load()))
    if command == "ran-none" and len(sys.argv) == 2:
        sys.exit(ran_none(load()))
    if command == "check-classes" and len(sys.argv) >= 5:
        sys.exit(check_classes(load(), sys.argv[2], sys.argv[3], sys.argv[4:]))
    if command == "infra-only" and len(sys.argv) == 3:
        sys.exit(infra_only(sys.argv[2]))
    if command == "app-crashed" and len(sys.argv) == 4:
        sys.exit(app_crashed(sys.argv[2], sys.argv[3]))
    print(__doc__, file=sys.stderr)
    sys.exit(64)
