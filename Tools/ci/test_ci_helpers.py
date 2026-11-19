#!/usr/bin/env python3
"""Fixture tests for Tools/ci/sim-state.py and Tools/ci/xcresult-tests.py. Linux, seconds:
Tools/ci/check.sh runs them in CI's Linux job, before any simulator shard spends an hour."""
import json
import os
import pathlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent


def run(script, args, stdin=""):
    result = subprocess.run([sys.executable, str(HERE / script), *args], input=stdin,
                            capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def bundle(cases):
    """xcresulttool-shaped tree: one UI test bundle, suites holding (class, method, result, messages)."""
    suites = {}
    for cls, method, result, messages in cases:
        suites.setdefault(cls, []).append({
            "nodeType": "Test Case", "name": method + "()", "nodeIdentifier": "%s/%s()" % (cls, method),
            "result": result,
            "children": [{"nodeType": "Failure Message", "name": m} for m in messages]})
    return json.dumps({"testNodes": [{"nodeType": "Test Plan", "name": "Herdr", "children": [{
        "nodeType": "UI test bundle", "name": "HerdrUITests", "children": [
            {"nodeType": "Test Suite", "name": cls, "children": children}
            for cls, children in suites.items()]}]}]})


class XcresultTests(unittest.TestCase):
    def test_failed_tests_lists_only_class_method_cases(self):
        data = json.loads(bundle([("A", "testOne", "Failed", ["x"]), ("A", "testTwo", "Passed", [])]))
        data["testNodes"][0]["children"][0]["children"].append({"nodeType": "Test Case", "result": "Failed",
            "nodeIdentifier": "HerdrUITests-Runner (21391) encountered an error"})
        code, out, _ = run("xcresult-tests.py", ["failed-tests"], json.dumps(data))
        self.assertEqual((code, out), (0, "-only-testing:HerdrUITests/A/testOne\n"))

    def test_ran_none(self):
        self.assertEqual(run("xcresult-tests.py", ["ran-none"], json.dumps({"testNodes": []}))[0], 0)
        self.assertEqual(run("xcresult-tests.py", ["ran-none"], bundle([("A", "testOne", "Passed", [])]))[0], 1)
        self.assertEqual(run("xcresult-tests.py", ["ran-none"], "not json")[0], 1)

    def test_check_classes_messages(self):
        ok = bundle([("A", "testOne", "Passed", []), ("B", "testTwo", "Failed", ["x"])])
        self.assertEqual(run("xcresult-tests.py", ["check-classes", "R/r-first.xcresult", "failed", "A", "B"], ok)[0], 0)
        code, out, _ = run("xcresult-tests.py", ["check-classes", "R/r-first.xcresult", "timeout", "A", "C"], ok)
        self.assertEqual(code, 1)
        self.assertIn("r ran out of its budget before C ran", out)
        code, out, _ = run("xcresult-tests.py", ["check-classes", "R/r-first.xcresult", "passed", "A", "C"], ok)
        self.assertIn("C executed no tests in this round", out)
        code, out, _ = run("xcresult-tests.py", ["check-classes", "R/r-first.xcresult", "unstarted", "A"], "")
        self.assertEqual(code, 1)
        self.assertIn("r left no readable result bundle", out)
        code, out, _ = run("xcresult-tests.py", ["check-classes", "R/r-first.xcresult", "unstarted", "A"],
                           json.dumps({"testNodes": []}))
        self.assertIn("r executed no test case", out)

    def issues_bundle(self, cases):
        """A result bundle whose database.sqlite3 holds the tables infra-only reads, in the
        columns Xcode 27.1 writes (runs 42770272602, 42815902188): (class/method, result,
        [(issue type, description)])."""
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory)
        db = sqlite3.connect(os.path.join(directory, "database.sqlite3"))
        db.executescript(
            "CREATE TABLE TestCases (testSuite_fk INTEGER, identifier TEXT, identifierURL TEXT,"
            " orderInTestSuite INTEGER, name TEXT, summary TEXT);"
            "CREATE TABLE TestCaseRuns (testSuiteRun_fk INTEGER, skipNotice_fk INTEGER,"
            " dynamicTestParameters_fk INTEGER, repetitionPolicy_fk INTEGER, orderInTestSuiteRun INTEGER,"
            " testCase_fk INTEGER, duration REAL, identifierURL TEXT, result TEXT);"
            "CREATE TABLE TestIssues (orderInOwner INTEGER, associatedError_fk INTEGER,"
            " detailedDescription TEXT, expression_fk INTEGER, testSuiteRun_fk INTEGER,"
            " sourceCodeContext_fk INTEGER, isTopLevel INTEGER, timestamp REAL, testCaseRun_fk INTEGER,"
            " compactDescription TEXT, sanitizedDescription TEXT, issueType TEXT, uuid TEXT);")
        for identifier, result, issues in cases:
            case = db.execute("INSERT INTO TestCases (identifier) VALUES (?)", (identifier + "()",)).lastrowid
            run_id = db.execute("INSERT INTO TestCaseRuns (testCase_fk, result) VALUES (?, ?)",
                                (case, result)).lastrowid
            for issue_type, description in issues:
                db.execute("INSERT INTO TestIssues (testCaseRun_fk, issueType, compactDescription)"
                           " VALUES (?, ?, ?)", (run_id, issue_type, description))
        db.commit()
        db.close()
        return directory

    def test_infra_only_goes_by_who_raised_the_failure(self):
        auto, assertion = "UI Automation Failure", "Assertion Failure"
        spring = "Critical process SpringBoard crashed in (null)"
        no_pid = "Application 'com.jerryfane.herdr' does not have a process ID"
        pid0 = "Failed to get background assertion for target app with pid 0: No failure details provided"
        # Run 42770272602's iPadResize and iPadGramColumn, as their bundles recorded them.
        infra = self.issues_bundle([
            ("DuoTransitionTests/testGramDraft", "Failure", [(auto, spring)]),
            ("DuoTransitionTests/testGramSearch", "Failure", [(auto, pid0)]),
            ("GramColumnTests/testDragging", "Failure", [(auto, no_pid)]),
            ("DuoTransitionTests/testTerminalDraft", "Success",
             [("Runtime Warning", "Modifying state during view update")])])
        code, out, _ = run("xcresult-tests.py", ["infra-only", infra])
        self.assertEqual(code, 0, out)
        # An assertion whose text merely reads like infrastructure is the test's own failure
        # (review of #649): XCTFail("Critical process SpringBoard crashed") must stay red.
        for text in (spring, no_pid, "XCTAssertTrue failed - " + no_pid):
            fake = self.issues_bundle([("A/testOne", "Failure", [(assertion, text)])])
            code, out, _ = run("xcresult-tests.py", ["infra-only", fake])
            self.assertEqual(code, 1, text)
            self.assertIn("TEST FAILURE A/testOne: [Assertion Failure]", out)
        # Any other issue on a failed case, an automation failure the app may cause included.
        mixed = self.issues_bundle([("A/testOne", "Failure", [(auto, spring)]),
                                    ("A/testTwo", "Failure", [(assertion, "XCTAssertTrue failed")])])
        self.assertEqual(run("xcresult-tests.py", ["infra-only", mixed])[0], 1)
        focus = self.issues_bundle([("A/testOne", "Failure", [(auto, "Failed to synthesize event: "
                                                               "Neither element nor any descendant has keyboard focus.")])])
        self.assertEqual(run("xcresult-tests.py", ["infra-only", focus])[0], 1)
        # The runner crashing (run 42808627997) is recorded as an assertion: no rerun.
        killed = self.issues_bundle([("A/testOne", "Failure", [(assertion, "Test crashed with signal kill.")])])
        self.assertEqual(run("xcresult-tests.py", ["infra-only", killed])[0], 1)
        # A signature that is not where the description starts is not that signature.
        quoted = self.issues_bundle([("A/testOne", "Failure", [(auto, "Expected: " + spring)])])
        self.assertEqual(run("xcresult-tests.py", ["infra-only", quoted])[0], 1)
        # Nothing to judge: no failed case, a failed case without an issue, no database.
        passed = self.issues_bundle([("A/testOne", "Success", [])])
        self.assertEqual(run("xcresult-tests.py", ["infra-only", passed])[0], 1)
        silent = self.issues_bundle([("A/testOne", "Failure", [])])
        self.assertEqual(run("xcresult-tests.py", ["infra-only", silent])[0], 1)
        self.assertEqual(run("xcresult-tests.py", ["infra-only", tempfile.gettempdir() + "/no-such.xcresult"])[0], 1)

    def test_no_app_crash_is_a_positive_check(self):
        herdr = "com.jerryfane.herdr"
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(run("xcresult-tests.py", ["no-app-crash", directory, herdr])[0], 0)
            with open(os.path.join(directory, "a.ips"), "w") as report:
                report.write(json.dumps({"bundleID": "com.apple.springboard"}) + "\n{}\n")
            self.assertEqual(run("xcresult-tests.py", ["no-app-crash", directory, herdr])[0], 0)
            with open(os.path.join(directory, "b.ips"), "w") as report:
                report.write(json.dumps({"bundleID": herdr}) + "\n{}\n")
            code, out, _ = run("xcresult-tests.py", ["no-app-crash", directory, herdr])
            self.assertEqual(code, 1)
            self.assertIn("crash report of %s" % herdr, out)
        with tempfile.TemporaryDirectory() as directory:
            # Unreadable: a report whose header is no JSON, a missing directory, no bundle id.
            with open(os.path.join(directory, "c.ips"), "w") as report:
                report.write("not json\n")
            self.assertEqual(run("xcresult-tests.py", ["no-app-crash", directory, herdr])[0], 1)
            self.assertEqual(run("xcresult-tests.py", ["no-app-crash", directory + "/missing", herdr])[0], 1)
            self.assertEqual(run("xcresult-tests.py", ["no-app-crash", directory, ""])[0], 1)
            # An exception: a header that is JSON but no object.
            with open(os.path.join(directory, "c.ips"), "w") as report:
                report.write("[1]\n")
            code, out, _ = run("xcresult-tests.py", ["no-app-crash", directory, herdr])
            self.assertEqual(code, 1)
            self.assertIn("AttributeError", out)

    def json_file(self, text):
        handle, path = tempfile.mkstemp(suffix=".json")
        self.addCleanup(os.remove, path)
        with os.fdopen(handle, "w") as target:
            target.write(text)
        return path

    def test_no_runner_error_is_a_positive_check(self):
        data = json.loads(bundle([("A", "testOne", "Failed", ["x"])]))
        self.assertEqual(run("xcresult-tests.py", ["no-runner-error", self.json_file(json.dumps(data))])[0], 0)
        data["testNodes"][0]["children"][0]["children"].append({"nodeType": "Test Case", "result": "Failed",
            "nodeIdentifier": "HerdrUITests-Runner (21391) encountered an error"})
        code, out, _ = run("xcresult-tests.py", ["no-runner-error", self.json_file(json.dumps(data))])
        self.assertEqual(code, 1)
        self.assertIn("runner error", out)
        for garbage in ("not json", "", "[]", '{"testNodes": []}', '{"testNodes": {}}'):
            self.assertEqual(run("xcresult-tests.py", ["no-runner-error", self.json_file(garbage)])[0], 1, garbage)
        self.assertEqual(run("xcresult-tests.py", ["no-runner-error", tempfile.gettempdir() + "/no-such.json"])[0], 1)
        code, out, _ = run("xcresult-tests.py", ["no-runner-error", self.json_file('{"testNodes": ["x"]}')])
        self.assertEqual(code, 1)
        self.assertIn("AttributeError", out)

    def test_no_crash_issues_is_a_positive_check(self):
        assertion, auto = "Assertion Failure", "UI Automation Failure"
        plain = self.issues_bundle([("A/testOne", "Failure", [(assertion, "XCTAssertTrue failed")]),
                                    ("A/testTwo", "Failure", [])])
        self.assertEqual(run("xcresult-tests.py", ["no-crash-issues", plain])[0], 0)
        crashed = self.issues_bundle([("A/testOne", "Failure", [(auto, "Herdr crashed in Foo.bar()")])])
        code, out, _ = run("xcresult-tests.py", ["no-crash-issues", crashed])
        self.assertEqual(code, 1)
        self.assertIn("A/testOne()", out)
        # Unreadable: no database, or one that records no failed case.
        self.assertEqual(run("xcresult-tests.py", ["no-crash-issues", tempfile.gettempdir() + "/no-such.xcresult"])[0], 1)
        passed = self.issues_bundle([("A/testOne", "Success", [])])
        self.assertEqual(run("xcresult-tests.py", ["no-crash-issues", passed])[0], 1)
        # An exception: a description stored as a blob, which the text pattern cannot search.
        odd = self.issues_bundle([("A/testOne", "Failure", [(assertion, b"crash")])])
        code, out, _ = run("xcresult-tests.py", ["no-crash-issues", odd])
        self.assertEqual(code, 1)
        self.assertIn("TypeError", out)

    def test_all_passed_needs_every_retried_case_passed_and_nothing_else(self):
        one, two = "-only-testing:HerdrUITests/A/testOne", "-only-testing:HerdrUITests/A/testTwo"
        def all_passed(text, *selectors):
            return run("xcresult-tests.py", ["all-passed", self.json_file(text), *selectors])[0]
        self.assertEqual(all_passed(bundle([("A", "testOne", "Passed", []), ("A", "testTwo", "Passed", [])]), one, two), 0)
        # A case that did not run, failed, or was skipped keeps the failure.
        self.assertEqual(all_passed(bundle([("A", "testOne", "Passed", [])]), one, two), 1)
        self.assertEqual(all_passed(bundle([("A", "testOne", "Passed", []), ("A", "testTwo", "Failed", ["x"])]),
                                    one, two), 1)
        self.assertEqual(all_passed(bundle([("A", "testOne", "Skipped", [])]), one), 1)
        # A runner error next to passing cases, no test case at all, or no readable bundle.
        data = json.loads(bundle([("A", "testOne", "Passed", [])]))
        data["testNodes"][0]["children"][0]["children"].append({"nodeType": "Test Case", "result": "Failed",
            "nodeIdentifier": "HerdrUITests-Runner (21391) encountered an error"})
        self.assertEqual(all_passed(json.dumps(data), one), 1)
        self.assertEqual(all_passed(json.dumps({"testNodes": []}), one), 1)
        self.assertEqual(all_passed("not json", one), 1)
        self.assertEqual(run("xcresult-tests.py", ["all-passed", tempfile.gettempdir() + "/no-such.json", one])[0], 1)
        # An exception: a node that is no object.
        self.assertEqual(all_passed('{"testNodes": [{"children": ["x"]}]}', one), 1)


class RetryGateTests(unittest.TestCase):
    """ui-shard.sh's retry_failed_tests, run as the production functions with xcrun,
    xcodebuild and the bundle identifier stubbed: only a retry every gate checked as clean
    passes the round; a stub that fails or returns nothing usable keeps the failure."""

    FUNCTIONS = ("beautify", "retry_failed_tests", "no_app_crash_in")
    SELECTOR = "-only-testing:HerdrUITests/A/testOne"
    issues_bundle = XcresultTests.issues_bundle

    @classmethod
    def setUpClass(cls):
        source = (HERE / "ui-shard.sh").read_text()
        bodies = []
        for name in cls.FUNCTIONS:
            match = re.search(r"^%s\(\) \{\n.*?^\}\n" % name, source, re.M | re.S)
            assert match, "ui-shard.sh has no function %s" % name
            bodies.append(match.group(0))
        cls.functions = "".join(bodies)

    def retry(self, **fake):
        """Runs retry_failed_tests L on one failed case; returns (status, output, FLAKES.txt)."""
        work = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work)
        first = work / "TestReceipts" / "L-first.xcresult"
        first.mkdir(parents=True)
        database = pathlib.Path(self.issues_bundle(fake.pop("issues", [("A/testOne", "Failure", [])])))
        shutil.copy(database / "database.sqlite3", first / "database.sqlite3")
        (work / "first.json").write_text(fake.pop("first", bundle([("A", "testOne", "Failed", ["x"])])))
        (work / "retry.json").write_text(fake.pop("retry", bundle([("A", "testOne", "Passed", [])])))
        if "ips" in fake:
            (work / "report.ips").write_text(fake.pop("ips"))
        harness = """set -uo pipefail
cd "$WORK" || exit 99
SIM_TMP="$WORK/sim"; mkdir -p "$SIM_TMP"
XCRESULT_TESTS="${FAKE_XCRESULT_TESTS:-$HERE/xcresult-tests.py}"
PROJECT=(-project Herdr.xcodeproj -scheme Herdr)
TIMEOUT_BIN=fake_timeout
fake_timeout() { shift 2; "$@"; }
xcodebuild() { return "${FAKE_XCODEBUILD:-0}"; }
bundle_identifier() { echo com.jerryfane.herdr; }
xcrun() {
  local which=retry
  case "$2 $3" in
    "get test-results")
      case "$6" in *-first.xcresult) which=first ;; esac
      [ "${FAKE_GET:-}" = "$which" ] && { echo "xcresulttool: cannot open $6" >&2; return 1; }
      cat "$WORK/$which.json" ;;
    "export attachments")
      case "$5" in *-first.xcresult) which=first ;; esac
      [ "${FAKE_EXPORT:-}" = "$which" ] && return 1
      mkdir -p "$7"
      if [ -f "$WORK/report.ips" ] && [ "${FAKE_IPS_IN:-$which}" = "$which" ]; then cp "$WORK/report.ips" "$7/"; fi ;;
    *) return 1 ;;
  esac
}
%s
retry_failed_tests L udid "%s" app
""" % (self.functions, self.SELECTOR)
        env = dict(os.environ, WORK=str(work), HERE=str(HERE))
        env.update({"FAKE_" + key.upper(): value for key, value in fake.items()})
        result = subprocess.run(["bash", "-c", harness], env=env, capture_output=True, text=True)
        flakes = work / "TestReceipts" / "FLAKES.txt"
        return result.returncode, result.stdout + result.stderr, flakes.read_text() if flakes.exists() else None

    def test_a_clean_retry_passes_and_records_the_flake(self):
        code, out, flakes = self.retry()
        self.assertEqual(code, 0, out)
        self.assertEqual(flakes, "L A/testOne\n")
        self.assertIn("::warning::flaky (passed on retry): L A/testOne", out)

    def test_every_gate_that_cannot_check_or_finds_something_keeps_the_failure(self):
        herdr_crash = json.dumps({"bundleID": "com.jerryfane.herdr"}) + "\n{}\n"
        first_record = "the first run's record does not show only test-case failures"
        first_issues = "the first run's issues mention a crash or cannot be read"
        first_crash = "the first run's attachments do not show that com.jerryfane.herdr did not crash"
        retry_record = "the retry's result bundle does not show every failed test passed"
        retry_crash = "the retry's attachments do not show that com.jerryfane.herdr did not crash"
        cases = {
            "xcresulttool cannot read the first bundle": ({"get": "first"}, "cannot read the first run's result bundle"),
            "xcresulttool cannot read the retry bundle": ({"get": "retry"}, "cannot read the retry's result bundle"),
            "the first attachments cannot be exported": ({"export": "first"}, first_crash),
            "the retry attachments cannot be exported": ({"export": "retry"}, retry_crash),
            "the retry failed": ({"xcodebuild": "65"}, "the retry failed too (xcodebuild exit 65)"),
            "the first record is garbage": ({"first": "not json"}, first_record),
            "the first record is empty": ({"first": ""}, first_record),
            "the first run had a runner error": ({"first": json.dumps({"testNodes": [{
                "nodeType": "UI test bundle", "name": "HerdrUITests", "children": [
                    {"nodeType": "Test Case", "result": "Failed", "nodeIdentifier": "A/testOne()"},
                    {"nodeType": "Test Case", "result": "Failed",
                     "nodeIdentifier": "HerdrUITests-Runner (1) encountered an error"}]}]})}, first_record),
            "an issue mentions a crash": (
                {"issues": [("A/testOne", "Failure", [("Assertion Failure", "Herdr crashed")])]}, first_issues),
            "the database records no failure": ({"issues": [("A/testOne", "Success", [])]}, first_issues),
            "the app crashed in the first run": ({"ips": herdr_crash, "ips_in": "first"}, first_crash),
            "the app crashed in the retry": ({"ips": herdr_crash, "ips_in": "retry"}, retry_crash),
            "a crash report cannot be read": ({"ips": "not json\n"}, first_crash),
            "the retry's record is garbage": ({"retry": "{"}, retry_record),
            "the retry ran nothing": ({"retry": json.dumps({"testNodes": []})}, retry_record),
            "the retry failed the case": ({"retry": bundle([("A", "testOne", "Failed", ["x"])])}, retry_record),
            "the helper is missing": ({"xcresult_tests": "/nonexistent/xcresult-tests.py"}, first_record),
        }
        for name, (fake, verdict) in cases.items():
            with self.subTest(name):
                code, out, flakes = self.retry(**fake)
                self.assertEqual(code, 1, out)
                self.assertIsNone(flakes, out)
                self.assertIn("first run failed and %s; the failure stands" % verdict, out)


class SimStateTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        mounted = pathlib.Path(self.dir.name, "mnt")
        (mounted / "Library/Developer/CoreSimulator/Profiles/Runtimes").mkdir(parents=True)
        self.devices = self.write("devices.json", {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
            {"udid": "U1", "isAvailable": True, "state": "Booted"},
            {"udid": "U2", "isAvailable": False, "state": "Shutdown",
             "availabilityError": "runtime profile not found"}]}})
        self.mounted = str(mounted)

    def write(self, name, value):
        path = os.path.join(self.dir.name, name)
        with open(path, "w") as out:
            json.dump(value, out)
        return path

    def runtimes(self, ios_path):
        return self.write("runtimes.json", {
            "A": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "build": "24B",
                  "state": "Ready", "mountPath": ios_path},
            "B": {"runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "build": "24R",
                  "state": "Unusable - Cryptex Mount Preferred"}})

    def test_device_states(self):
        self.assertEqual(run("sim-state.py", ["device", self.devices, "U1"])[:2], (0, "Booted\n"))
        self.assertEqual(run("sim-state.py", ["device", self.devices, "U2"])[0], 3)
        self.assertEqual(run("sim-state.py", ["device", self.devices, "U9"])[0], 1)

    def test_runtime_mounted_or_not(self):
        self.assertEqual(run("sim-state.py", ["runtimes", self.runtimes(self.mounted), self.devices, "U1"])[0], 0)
        gone = self.runtimes(os.path.join(self.dir.name, "gone"))
        code, out, _ = run("sim-state.py", ["runtimes", gone, self.devices, "U1"])
        self.assertEqual(code, 1)
        self.assertIn("NOT MOUNTED", out)


if __name__ == "__main__":
    unittest.main()
