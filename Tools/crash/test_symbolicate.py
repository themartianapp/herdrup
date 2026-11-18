#!/usr/bin/env python3
"""symbolicate.py writes one .txt per input report, whatever the inputs are named. Linux,
seconds, no symbolizer or dSYMs needed: Tools/ci/check.sh runs it in CI's Linux job."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().with_name("symbolicate.py")


def report(build):
    return {"v": 1, "kind": "crash", "version": "1.3.4", "build": build, "os": "iPhone OS 27.2 (24C101)",
            "device": "iPhone19,4", "binaries": [{"name": "Herdr", "uuid": "913AE206-9644-328F-9952-176ECA385CA0"}],
            "stacks": [{"attributed": True, "frames": [[0, 740520]]}]}


class OutputPathTests(unittest.TestCase):
    def test_reports_with_the_same_file_name_each_keep_their_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            inputs = []
            for folder, build in (("a", "244"), ("b", "245")):
                (tmp / folder).mkdir()
                path = tmp / folder / "report.json"
                path.write_text(json.dumps(report(build)))
                inputs.append(str(path))
            (tmp / "no-dsyms").mkdir()
            out = tmp / "out"
            subprocess.run([sys.executable, str(SCRIPT), "--report", *inputs, "--dsyms", str(tmp / "no-dsyms"),
                            "--out", str(out)], check=True, capture_output=True, text=True)
            texts = sorted(path.read_text() for path in out.glob("*.txt"))
            self.assertEqual(len(texts), 2, sorted(path.name for path in out.glob("*.txt")))
            self.assertIn("(244)", texts[0])
            self.assertIn("(245)", texts[1])

    def test_a_name_like_a_clash_prefix_does_not_overwrite_another_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            inputs = []
            for path, build in (("a/report.json", "244"), ("b/report.json", "245"), ("0-report.json", "246")):
                path = tmp / path
                path.parent.mkdir(exist_ok=True)
                path.write_text(json.dumps(report(build)))
                inputs.append(str(path))
            (tmp / "no-dsyms").mkdir()
            out = tmp / "out"
            subprocess.run([sys.executable, str(SCRIPT), "--report", *inputs, "--dsyms", str(tmp / "no-dsyms"),
                            "--out", str(out)], check=True, capture_output=True, text=True)
            texts = sorted(path.read_text() for path in out.glob("*.txt"))
            self.assertEqual(len(texts), 3, sorted(path.name for path in out.glob("*.txt")))
            for text, build in zip(texts, ("244", "245", "246")):
                self.assertIn(f"({build})", text)


if __name__ == "__main__":
    unittest.main()
