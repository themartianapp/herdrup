#!/usr/bin/env python3
"""Reads `xcrun xcresulttool get test-results tests --path BUNDLE` JSON on stdin for
Tools/ci/ui-shard.sh. A separate file, not `python3 -c '…'` inside the shell script: a single
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

  xcresult-tests.py infra-only
      Exits 0 when the bundle has failed test cases and every failure message of every one
      is a simulator/XCTest infrastructure signature (INFRASTRUCTURE below), printing each
      message with its verdict; exits 1 when any failure is anything else, an assertion
      above all.

  xcresult-tests.py app-crashed ATTACHMENTS_DIR BUNDLE_ID
      Exits 0 when the exported attachments hold a crash report (.ips) of BUNDLE_ID.
"""
import glob
import json
import os
import re
import sys

CASE = re.compile(r"\w+/\w+")

# Failures that say the simulator or XCTest could not run the app, not what the app did.
# Each was followed by a passing diagnostic rerun of the same tests on the same commit:
#  - a simulator system process (never the app under test) crashed mid-test: "Critical
#    process SpringBoard crashed" (run 42770272602 iPadResize: SpringBoard SIGBUS in
#    NSXPCEncoder), "Critical process runningboardd crashed";
#  - the app never got a process: "Application 'com.jerryfane.herdr' does not have a process
#    ID" from app.launch() after 153 s (42770272602 iPadGramColumn, no crash report of the
#    app), and the follow-on "Failed to get background assertion for target app with pid 0";
#  - XCTest could not kill the previous launch: "Failed to terminate com.jerryfane.herdr:N:
#    Failed to terminate com.jerryfane.herdr:0" (42273527812 and seven more).
INFRASTRUCTURE = [
    re.compile(r"Critical process \S+ crashed"),
    re.compile(r"Application '[\w.]+' does not have a process ID"),
    re.compile(r"Failed to get background assertion for target app with pid 0\b"),
    re.compile(r"Failed to terminate [\w.]+:\d+: Failed to terminate [\w.]+:0\b"),
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


def infra_only(data):
    failures = {}  # Class/method -> failure messages
    def walk(node, case):
        if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
            case = identifier(node)
            failures.setdefault(case, [])
        elif node.get("nodeType") == "Failure Message" and case is not None:
            failures[case].append(node.get("name", ""))
        for child in node.get("children", []):
            walk(child, case)
    for node in (data or {}).get("testNodes", []):
        walk(node, None)
    if not failures:
        return 1
    verdict = 0
    for case, messages in sorted(failures.items()):
        if not CASE.fullmatch(case) or not messages:
            print("TEST FAILURE %s: not a Class/method failure with a message" % case)
            verdict = 1
        for message in messages:
            infra = any(pattern.search(message) for pattern in INFRASTRUCTURE)
            print("%s %s: %s" % ("infrastructure" if infra else "TEST FAILURE", case, message[:300]))
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
    if command == "infra-only" and len(sys.argv) == 2:
        sys.exit(infra_only(load()))
    if command == "app-crashed" and len(sys.argv) == 4:
        sys.exit(app_crashed(sys.argv[2], sys.argv[3]))
    print(__doc__, file=sys.stderr)
    sys.exit(64)
