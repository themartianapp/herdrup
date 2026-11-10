#!/usr/bin/env python3
"""Fixture tests for Tools/ci/sim-state.py and Tools/ci/xcresult-tests.py. Linux, seconds:
Tools/ci/check.sh runs them in CI's Linux job, before any simulator shard spends an hour."""
import json
import os
import pathlib
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
        self.assertEqual(run("sim-state.py", ["runtimes", self.runtimes(self.mounted)])[0], 0)
        self.assertEqual(run("sim-state.py", ["runtimes", self.runtimes(self.mounted), self.devices, "U1"])[0], 0)
        gone = self.runtimes(os.path.join(self.dir.name, "gone"))
        code, out, _ = run("sim-state.py", ["runtimes", gone, self.devices, "U1"])
        self.assertEqual(code, 1)
        self.assertIn("NOT MOUNTED", out)


if __name__ == "__main__":
    unittest.main()
