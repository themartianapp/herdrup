"""Tests for ci_scope.py. Tools/ci/check.sh runs them, in CI's Linux job and locally."""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from ci_scope import BUILD_DIRS, ZERO_SHA, is_docs_path, ui_reason

REPO = Path(__file__).resolve().parents[2]
PROJECT_YML = (REPO / "project.yml").read_text()


def bump(text: str, key: str, value: str) -> str:
    """Sets every `key: "..."` in project.yml to `value`, keeping each line's shape."""
    bumped, count = re.subn(rf'^(\s*{key}: )"[^"]*"$', rf'\g<1>"{value}"', text, flags=re.M)
    assert count, f"project.yml has no {key} line"
    return bumped


class UiReasonTests(unittest.TestCase):
    """End to end against a scratch repository whose base holds the real project.yml."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "ci")
        self.write("project.yml", PROJECT_YML)
        self.write("README.md", "readme\n")
        self.write("docs/guide.md", "guide\n")
        self.write("App/HerdrApp.swift", "struct HerdrApp {}\n")
        self.write(".github/workflows/ci.yml", "name: CI\n")
        self.write("Tools/ci/ci_scope.py", "print()\n")
        self.base = self.commit("base")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def write(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        self.git("add", path)

    def commit(self, message: str) -> str:
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def reason(self, base: str | None = None) -> str | None:
        head = self.git("rev-parse", "HEAD")
        cwd = Path.cwd()
        try:
            os.chdir(self.repo)
            return ui_reason(self.base if base is None else base, head)
        finally:
            os.chdir(cwd)

    def assertSkips(self) -> None:
        self.assertIsNone(self.reason())

    def assertRuns(self) -> None:
        self.assertIsNotNone(self.reason())

    # Version numbers.

    def test_a_marketing_version_bump_skips_the_matrix(self) -> None:
        # The shape of #645: the same value changed in all four targets.
        self.write("project.yml", bump(PROJECT_YML, "MARKETING_VERSION", "99.0.1"))
        self.commit("chore: version 99.0.1")
        self.assertSkips()

    def test_a_build_number_bump_with_the_version_skips_the_matrix(self) -> None:
        text = bump(bump(PROJECT_YML, "MARKETING_VERSION", "99.0.1"), "CURRENT_PROJECT_VERSION", "7")
        self.write("project.yml", text)
        self.commit("chore: version 99.0.1 (7)")
        self.assertSkips()

    def test_a_version_bump_plus_another_project_line_runs_the_matrix(self) -> None:
        text = bump(PROJECT_YML, "MARKETING_VERSION", "99.0.1")
        text = text.replace('SWIFT_VERSION: "5.9"', 'SWIFT_VERSION: "6.0"', 1)
        self.write("project.yml", text)
        self.commit("version and swift")
        self.assertRuns()

    def test_a_version_bump_plus_a_comment_runs_the_matrix(self) -> None:
        text = bump(PROJECT_YML, "MARKETING_VERSION", "99.0.1") + "# trailing note\n"
        self.write("project.yml", text)
        self.commit("version and comment")
        self.assertRuns()

    def test_adding_a_version_setting_runs_the_matrix(self) -> None:
        text = PROJECT_YML.replace(
            '        MARKETING_VERSION: "', '        MARKETING_VERSION: "1.0"\n        MARKETING_VERSION: "', 1
        )
        self.write("project.yml", text)
        self.commit("duplicate key")
        self.assertRuns()

    def test_moving_a_version_to_another_key_runs_the_matrix(self) -> None:
        line = re.search(r'^(\s*)MARKETING_VERSION: "([^"]*)"$', PROJECT_YML, flags=re.M)
        assert line
        text = PROJECT_YML.replace(line[0], f'{line[1]}CURRENT_PROJECT_VERSION: "{line[2]}"', 1)
        self.write("project.yml", text)
        self.commit("version becomes build number")
        self.assertRuns()

    def test_changing_the_plist_version_reference_runs_the_matrix(self) -> None:
        text = PROJECT_YML.replace('"$(MARKETING_VERSION)"', '"1.0"', 1)
        self.write("project.yml", text)
        self.commit("hard-code the plist version")
        self.assertRuns()

    def test_a_project_mode_change_runs_the_matrix(self) -> None:
        (self.repo / "project.yml").chmod(0o755)
        self.git("add", "project.yml")
        self.commit("chmod")
        self.assertRuns()

    # Docs.

    def test_a_docs_only_change_skips_the_matrix(self) -> None:
        self.write("docs/guide.md", "guide, revised\n")
        self.write("docs/img/diagram.png", "png\n")
        self.write("README.md", "readme, revised\n")
        self.write("design/README.md", "design notes\n")
        self.write("LICENSE", "license\n")
        self.write(".github/ISSUE_TEMPLATE/bug.yml", "name: Bug\n")
        self.commit("docs")
        self.assertSkips()

    def test_docs_with_a_version_bump_skip_the_matrix(self) -> None:
        self.write("project.yml", bump(PROJECT_YML, "MARKETING_VERSION", "99.0.1"))
        self.write("README.md", "readme, revised\n")
        self.commit("version and readme")
        self.assertSkips()

    def test_deleting_a_doc_skips_the_matrix(self) -> None:
        self.git("rm", "-q", "docs/guide.md")
        self.commit("drop guide")
        self.assertSkips()

    def test_markdown_the_build_copies_runs_the_matrix(self) -> None:
        # xcodegen copies non-code files under App/ and HerdrUITests/ into the bundles.
        self.write("App/Resources/NOTES.md", "notes\n")
        self.commit("bundled markdown")
        self.assertRuns()

    # Code.

    def test_a_swift_change_runs_the_matrix(self) -> None:
        self.write("App/HerdrApp.swift", "struct HerdrApp { let x = 1 }\n")
        self.commit("swift")
        self.assertRuns()

    def test_a_ci_workflow_change_runs_the_matrix(self) -> None:
        self.write(".github/workflows/ci.yml", "name: CI changed\n")
        self.commit("ci")
        self.assertRuns()

    def test_a_classifier_change_runs_the_matrix(self) -> None:
        self.write("Tools/ci/ci_scope.py", "print('changed')\n")
        self.commit("classifier")
        self.assertRuns()

    def test_mixed_docs_and_code_runs_the_matrix(self) -> None:
        self.write("README.md", "readme, revised\n")
        self.write("App/HerdrApp.swift", "struct HerdrApp { let x = 1 }\n")
        self.commit("mixed")
        self.assertRuns()

    def test_renaming_code_into_docs_runs_the_matrix(self) -> None:
        self.git("mv", "App/HerdrApp.swift", "docs/HerdrApp.swift")
        self.commit("move code into docs")
        self.assertRuns()

    def test_renaming_a_doc_runs_the_matrix(self) -> None:
        self.git("mv", "docs/guide.md", "docs/handbook.md")
        self.commit("rename doc")
        self.assertRuns()

    # Unresolved ranges.

    def test_an_unknown_or_missing_base_runs_the_matrix(self) -> None:
        self.write("README.md", "readme, revised\n")
        self.commit("docs")
        self.assertIsNotNone(self.reason(ZERO_SHA))
        self.assertIsNotNone(self.reason("f" * 40))
        self.assertIsNotNone(self.reason(""))

    def test_no_change_runs_the_matrix(self) -> None:
        self.assertIsNotNone(self.reason(self.git("rev-parse", "HEAD")))


class DocsPathTests(unittest.TestCase):
    def test_markdown_outside_the_build_is_docs(self) -> None:
        for path in ("README.md", "GuestRelay/README.md", "design/reference/gram/README.md", "goals/x.md"):
            self.assertTrue(is_docs_path(path), path)

    def test_markdown_inside_the_build_is_not_docs(self) -> None:
        for path in (
            "App/Resources/Mermaid/README.md",
            "HerdrUITests/Fixtures/PROVENANCE.md",
            "Vendor/SwiftTerm/Sources/SwiftTerm/Documentation.docc/GettingStarted.md",
        ):
            self.assertFalse(is_docs_path(path), path)

    def test_build_dirs_cover_every_project_source_directory(self) -> None:
        # A target added to project.yml from a new top-level directory must be added to
        # BUILD_DIRS, or Markdown it bundles would count as docs and skip the matrix.
        sources = re.findall(r"^\s*(?:- )?path: ([^\s#]+)", PROJECT_YML, flags=re.M)
        tops = {source.split("/")[0] + "/" for source in sources if source != "."}
        self.assertTrue(tops)
        self.assertEqual(sorted(tops - set(BUILD_DIRS)), [])


if __name__ == "__main__":
    unittest.main()
