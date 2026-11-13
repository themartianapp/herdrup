#!/usr/bin/env python3
"""The device suite's macserve shards in .macserve.json cover every test class. Linux, seconds:
Tools/ci/check.sh runs it in CI's Linux job.

macserve's UI-test template runs exactly the -only-testing selectors a ui_test shard lists, so
a new test class that no shard names would run nowhere. Every class with test methods in
HerdrUITests and HerdrFontTests must therefore appear as a whole class in an iPhone shard
(iphone-terminal or iphone-app, exactly one of them), or, for an iPad-only class, as a whole
class in the ipad shard, or be one of the classes the `ipad-script` script shard runs
(Herdrup Desktop's references, ui-shard.sh DESKTOP_REFERENCE_CLASSES). Every selector must
name an existing class or method."""
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
IPHONE_SHARDS = ("iphone-terminal", "iphone-app")


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
                self.assertEqual(homes, [], "%s runs in ipad-script; no iPhone shard needs it" % key)
                continue
            self.assertLessEqual(len(homes), 1, "%s is in more than one iPhone shard: %s" % (key, homes))
            self.assertTrue(homes or key in whole["ipad"],
                            "%s is in no shard: add it to %s, or to ipad if it is iPad-only" % (key, IPHONE_SHARDS))
        self.assertTrue(self.script_classes <= set(self.classes), "DESKTOP_REFERENCE_CLASSES names a missing class")


if __name__ == "__main__":
    unittest.main()
