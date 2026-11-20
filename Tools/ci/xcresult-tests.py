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

THE RETRY GATES ARE POSITIVE CHECKS. ui-shard.sh lets a failed round pass on its retry only
when each of these exits 0, so 0 means "read the input and found nothing", and everything
else (a finding, unreadable or unexpected input, a missing file, any exception) exits 1
with the reason printed. Review of #747: the first shape, "exit 0 when a crash is found",
read an unreadable bundle or a Python exception as clean.

  xcresult-tests.py no-app-crash ATTACHMENTS_DIR BUNDLE_ID
      Exits 0 only when ATTACHMENTS_DIR exists and holds no crash report (.ips) of
      BUNDLE_ID. A report whose header cannot be read counts as the app's.

  xcresult-tests.py no-runner-error BUNDLE_JSON_FILE
      Exits 0 only when BUNDLE_JSON_FILE (`xcresulttool get test-results tests` output)
      records test cases and no failed one outside a Class/method case (the test runner's
      own error, see failed-tests): a round whose runner failed outside its tests is never
      retried into a pass.

  xcresult-tests.py no-crash-issues BUNDLE
      Exits 0 only when the bundle's database records failed test cases and no issue
      recorded against one of them mentions a crash.

  xcresult-tests.py all-passed BUNDLE_JSON_FILE SELECTOR...
      Exits 0 only when every -only-testing:Bundle/Class/method SELECTOR is recorded as a
      passed test case and no test case has any other result.

Every command exits 1 on an exception: for the others, too, 1 is the cautious answer (a
round may have run, a class is missing, a failure is not infrastructure).
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


def no_app_crash(directory, bundle_id):
    if not bundle_id:
        print("no bundle identifier to look for")
        return 1
    if not os.path.isdir(directory):
        print("no attachments directory %s" % directory)
        return 1
    verdict = 0
    for report in sorted(glob.glob(os.path.join(directory, "**", "*.ips"), recursive=True)):
        try:
            with open(report, errors="replace") as source:
                header = json.loads(source.readline())
        except (OSError, ValueError) as error:
            print("unreadable crash report %s (%s): it may be the app's" % (report, error))
            verdict = 1
            continue
        if header.get("bundleID") == bundle_id:
            print("crash report of %s: %s" % (bundle_id, report))
            verdict = 1
    return verdict


def load_file(path):
    """The `xcresulttool get test-results tests` JSON in path, or None (reason printed)."""
    try:
        with open(path) as source:
            data = json.load(source)
    except (OSError, ValueError) as error:
        print("cannot read %s: %s" % (path, error))
        return None
    if not isinstance(data, dict) or not isinstance(data.get("testNodes"), list):
        print("%s holds no testNodes list" % path)
        return None
    return data


def test_cases(data):
    """[(Bundle/Class/method or the raw identifier, result)] for every test case in data."""
    cases = []
    def walk(node, bundle):
        if node.get("nodeType") in ("UI test bundle", "Unit test bundle"):
            bundle = node.get("name")
        if node.get("nodeType") == "Test Case":
            cases.append(("%s/%s" % (bundle, identifier(node)), node.get("result")))
        for child in node.get("children", []):
            walk(child, bundle)
    for node in data["testNodes"]:
        walk(node, None)
    return cases


def no_runner_error(path):
    data = load_file(path)
    if data is None:
        return 1
    cases = test_cases(data)
    if not cases:
        print("%s records no test case" % path)
        return 1
    errors = [case for case, result in cases
              if result == "Failed" and not CASE.fullmatch(case.partition("/")[2])]
    for case in errors:
        print("runner error: %s" % case)
    return 1 if errors else 0


CRASH = re.compile(r"crash", re.I)


def no_crash_issues(bundle):
    database = os.path.join(bundle, "database.sqlite3")
    try:
        connection = sqlite3.connect("file:%s?mode=ro" % database, uri=True)
        rows = connection.execute(
            "SELECT tc.identifier, ti.compactDescription"
            " FROM TestCaseRuns tcr JOIN TestCases tc ON tcr.testCase_fk = tc.rowid"
            " LEFT JOIN TestIssues ti ON ti.testCaseRun_fk = tcr.rowid"
            " WHERE tcr.result = 'Failure'").fetchall()
    except sqlite3.Error as error:
        print("cannot read the issues of %s: %s" % (bundle, error))
        return 1
    if not rows:
        # The round failed: a database with no failed case is not the one it wrote.
        print("%s records no failed test case" % database)
        return 1
    crashes = [(case, description) for case, description in rows
               if description is not None and CRASH.search(description)]
    for case, description in crashes:
        print("crash %s: %s" % (case, description.replace("\n", " ")[:300]))
    return 1 if crashes else 0


def all_passed(path, selectors):
    data = load_file(path)
    if data is None:
        return 1
    results = {}
    for case, result in test_cases(data):
        results.setdefault(case, set()).add(result)
    verdict = 0
    for selector in selectors:
        case = selector.removeprefix("-only-testing:")
        if results.get(case) != {"Passed"}:
            print("retry: %s %s" % (case, "/".join(sorted(map(str, results.get(case, {"not run"}))))))
            verdict = 1
    for case, outcomes in sorted(results.items()):
        if outcomes != {"Passed"} and "-only-testing:" + case not in selectors:
            print("retry: %s %s" % (case, "/".join(sorted(map(str, outcomes)))))
            verdict = 1
    return verdict


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "failed-tests" and len(argv) == 2:
        return failed_tests(load())
    if command == "ran-none" and len(argv) == 2:
        return ran_none(load())
    if command == "check-classes" and len(argv) >= 5:
        return check_classes(load(), argv[2], argv[3], argv[4:])
    if command == "infra-only" and len(argv) == 3:
        return infra_only(argv[2])
    if command == "no-app-crash" and len(argv) == 4:
        return no_app_crash(argv[2], argv[3])
    if command == "no-runner-error" and len(argv) == 3:
        return no_runner_error(argv[2])
    if command == "no-crash-issues" and len(argv) == 3:
        return no_crash_issues(argv[2])
    if command == "all-passed" and len(argv) >= 4:
        return all_passed(argv[2], argv[3:])
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    try:
        status = main(sys.argv)
    except Exception as error:  # pylint: disable=broad-except
        # Never "clean" by accident: 1 is every command's cautious answer.
        print("%s: %s: %s" % (os.path.basename(sys.argv[0]), type(error).__name__, error))
        status = 1
    sys.exit(status)
