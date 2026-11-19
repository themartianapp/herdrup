#!/usr/bin/env python3
"""The device suite's macserve shards in .macserve.json cover every test class. Linux, seconds:
Tools/ci/check.sh runs it in CI's Linux job.

macserve's UI-test template runs exactly the -only-testing selectors a ui_test shard lists, so
a new test class that no shard names would run nowhere. Every class with test methods in
HerdrUITests and HerdrFontTests must therefore appear as a whole class in an iPhone shard
(iphone-terminal or iphone-app, exactly one of them), or, for an iPad-only class, as a whole
class in the ipad shard, or be one of the classes the `desktop-refs` script shard runs
(Herdrup Desktop's references, ui-shard.sh DESKTOP_REFERENCE_CLASSES). Every selector must
name an existing class or method, and every script shard's `run` an executable file. The
unit_test shards run SwiftTerm's UIKit API tests from the same Herdr scheme, so their target
must be in that scheme's test action (project.yml).

The `smoke` shard is the fast tier's: a few dozen tests run on every push, while the full
shards above still run before merge. It may overlap them, but only as a subset: each smoke
selector's class runs whole in an iPhone shard, so the full tier never misses what smoke runs.
Smoke does not count as a class's home. macserve refuses a shard with more than 32 selectors."""
import json
import os
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
IPHONE_SHARDS = ("iphone-terminal", "iphone-app")
SMOKE_SHARD = "smoke"
MAX_SELECTORS = 32


def test_classes(target):
    """{class: {test method names}} for the XCTestCase subclasses under ROOT/target."""
    classes = {}
    for path in sorted((ROOT / target).rglob("*.swift")):
        source = path.read_text()
        heads = list(re.finditer(r"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:", source, re.M))
        for index, head in enumerate(heads):
            end = heads[index + 1].start() if index + 1 < len(heads) else len(source)
            methods = set(re.findall(r"func\s+(test\w*)\s*\(", source[head.start():end]))
            if methods:
                classes.setdefault(head.group(1), set()).update(methods)
    return {"%s/%s" % (target, name): methods for name, methods in classes.items()}


class MacserveShardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        config = json.loads((ROOT / ".macserve.json").read_text())
        cls.ui = config["ui_test"]["shards"]
        cls.script = config["script"]["shards"]
        cls.unit = config["unit_test"]["shards"]
        cls.swiftterm_classes = {
            key.rpartition("/")[2]: methods
            for key, methods in test_classes("Vendor/SwiftTerm/Tests/SwiftTermTests").items()}
        cls.classes = {**test_classes("HerdrUITests"), **test_classes("HerdrFontTests")}
        cls.ui_shard = (ROOT / "Tools/ci/ui-shard.sh").read_text()
        references = re.search(r"^DESKTOP_REFERENCE_CLASSES=\(([^)]*)\)", cls.ui_shard, re.M)
        cls.script_classes = {"HerdrUITests/" + name for name in references.group(1).split()}

    def test_selectors_name_existing_classes_and_methods(self):
        for shard, selectors in self.ui.items():
            for selector in selectors:
                target, name, *method = selector.split("/")
                key = "%s/%s" % (target, name)
                self.assertIn(key, self.classes, "%s: %s is no test class" % (shard, selector))
                if method:
                    self.assertIn(method[0].removesuffix("()"), self.classes[key], "%s: %s" % (shard, selector))

    def test_every_class_runs_in_one_iphone_shard_or_on_ipad(self):
        whole = {shard: {s for s in selectors if s.count("/") == 1} for shard, selectors in self.ui.items()}
        for key in sorted(self.classes):
            homes = [shard for shard in IPHONE_SHARDS if key in whole[shard]]
            if key in self.script_classes:
                self.assertEqual(homes, [], "%s runs in desktop-refs; no iPhone shard needs it" % key)
                continue
            self.assertLessEqual(len(homes), 1, "%s is in more than one iPhone shard: %s" % (key, homes))
            self.assertTrue(homes or key in whole["ipad"],
                            "%s is in no shard: add it to %s, or to ipad if it is iPad-only" % (key, IPHONE_SHARDS))
        self.assertTrue(self.script_classes <= set(self.classes), "DESKTOP_REFERENCE_CLASSES names a missing class")

    def test_smoke_is_a_subset_of_the_iphone_shards(self):
        smoke = self.ui[SMOKE_SHARD]
        self.assertEqual(len(smoke), len(set(smoke)), "smoke names a selector twice")
        full = {selector for shard in IPHONE_SHARDS for selector in self.ui[shard]}
        for selector in smoke:
            key = "/".join(selector.split("/")[:2])
            self.assertTrue(key in full or selector in full,
                            "smoke: %s runs in no iPhone shard, so the full tier would skip it" % selector)

    def test_every_shard_fits_macserve(self):
        for shard, selectors in {**self.ui, **self.unit}.items():
            self.assertLessEqual(len(selectors), MAX_SELECTORS, "%s has more than %d selectors" % (shard, MAX_SELECTORS))

    def test_every_script_shard_runs_an_executable_file(self):
        for shard, spec in self.script.items():
            run = ROOT / spec["run"]
            self.assertTrue(run.is_file() and os.access(run, os.X_OK), "%s: %s is no executable file" % (shard, run))
        for shard in ("desktop-refs", "settings-stack"):
            self.assertRegex(self.ui_shard, r"(?m)^  %s\)$" % re.escape(shard), "ui-shard.sh has no %s case" % shard)

    def test_ipad_script_moved_to_parallel_shards(self):
        # 2026-11-19: its pieces run in parallel jobs; only the Settings regression keeps a
        # (short) script shard, and no shard may quietly bring the long one back.
        self.assertNotIn("ipad-script", self.script)
        self.assertIn("HerdrUITests/AgentListChromeTests", self.ui["ipad"])
        self.assertEqual(self.script["settings-stack"]["run"], "Tools/ci/macserve-settings-stack.sh")

    def test_swiftterm_unit_shards_run_from_the_herdr_scheme(self):
        # .macserve.json names one scheme for every shard: the unit_test shards' target must be
        # in the Herdr scheme's test action (project.yml), and each selector a SwiftTerm class.
        swiftterm = re.search(r"^SWIFTTERM_TESTS=(\S+)$", self.ui_shard, re.M).group(1)
        self.assertEqual(self.unit, {"swiftterm-ipad": [swiftterm], "swiftterm-iphone": [swiftterm]})
        self.assertRegex(self.ui_shard, r"(?m)^  swiftterm-ipad\|swiftterm-iphone\)$")
        classes = {"SwiftTermTests/" + name for name in self.swiftterm_classes}
        project = (ROOT / "project.yml").read_text()
        scheme = re.search(r"^    scheme:\n      testTargets:\n((?:        - .*\n)+)", project, re.M)
        self.assertIsNotNone(scheme, "project.yml's Herdr target has no scheme testTargets")
        for selectors in self.unit.values():
            for selector in selectors:
                target, name, *method = selector.split("/")
                self.assertIn("        - package: SwiftTerm/%s\n" % target, scheme.group(1),
                              "%s is not in the Herdr scheme's test action" % target)
                self.assertIn("%s/%s" % (target, name), classes, "%s is no SwiftTerm test class" % selector)
                if method:
                    self.assertIn(method[0].removesuffix("()"), self.swiftterm_classes[name], selector)


if __name__ == "__main__":
    unittest.main()
