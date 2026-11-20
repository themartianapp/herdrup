"""Tests for ci_scope.py. Tools/ci/check.sh runs them, in CI's Linux job and locally."""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from ci_scope import BUILD_DIRS, CI_WORKFLOW, NO_UI_PREFIXES, ZERO_SHA, is_no_ui_path, ui_reason

REPO = Path(__file__).resolve().parents[2]
PROJECT_YML = (REPO / "project.yml").read_text()
CI_YML = (REPO / CI_WORKFLOW).read_text()


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
        self.write(CI_WORKFLOW, CI_YML)
        self.write(".github/workflows/testflight.yml", "name: TestFlight\n")
        self.write("GuestRelay/src/relay.ts", "export const relay = 1;\n")
        self.write("AccountService/src/index.ts", "export const accounts = 1;\n")
        self.write("Tools/crash/symbolicate.py", "print()\n")
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

    def test_a_change_to_the_scope_jobs_workflow_outside_its_jobs_runs_the_matrix(self) -> None:
        self.write(CI_WORKFLOW, CI_YML.replace("name: CI\n", "name: CI changed\n", 1))
        self.commit("ci name")
        self.assertRuns()

    def test_a_change_to_the_scope_job_runs_the_matrix(self) -> None:
        for old, new in (
            ("    timeout-minutes: 5\n", "    timeout-minutes: 6\n"),
            ('python3 Tools/ci/ci_scope.py "$BASE" "$HEAD"', 'echo ui=false; true "$BASE" "$HEAD"'),
        ):
            with self.subTest(new=new):
                self.assertIn(old, CI_YML)
                self.git("checkout", "-q", self.base, "--", CI_WORKFLOW)
                self.write(CI_WORKFLOW, CI_YML.replace(old, new, 1))
                self.commit("scope job")
                self.assertRuns()

    def test_a_change_to_another_ci_job_skips_the_matrix(self) -> None:
        # The shape of #744: a new Linux job for AccountService next to the guest relay's.
        self.assertIn("        working-directory: GuestRelay\n", CI_YML)
        text = CI_YML.replace("        working-directory: GuestRelay\n", "        working-directory: ./GuestRelay\n", 1)
        text += "\n  accounts:\n    name: Accounts\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"
        self.write(CI_WORKFLOW, text)
        self.commit("another job")
        self.assertSkips()

    def test_a_header_comment_and_another_job_in_ci_skip_the_matrix(self) -> None:
        # The ci.yml half of #744: the file's header comment and a new job after the others.
        # Built from ci.yml's own first line, so a later header edit cannot break the test
        # (#744 itself reworded the line this test once replaced, and main's run failed).
        old = CI_YML.splitlines()[0]
        self.assertTrue(old.startswith("# "), "ci.yml no longer starts with a header comment: %r" % old)
        text = CI_YML.replace(old, old + " (and the account service Worker)", 1)
        text += "\n  # The account service Worker.\n  accounts:\n    runs-on: ubuntu-latest\n"
        self.write(CI_WORKFLOW, text)
        self.commit("header and job")
        self.assertSkips()

    def test_a_change_to_the_triggers_or_concurrency_runs_the_matrix(self) -> None:
        self.assertIn("  cancel-in-progress: true\n", CI_YML)
        self.write(CI_WORKFLOW, CI_YML.replace("  cancel-in-progress: true\n", "  cancel-in-progress: false\n", 1))
        self.commit("concurrency")
        self.assertRuns()

    def test_deleting_or_renaming_the_scope_jobs_workflow_runs_the_matrix(self) -> None:
        self.git("rm", "-q", CI_WORKFLOW)
        self.commit("drop ci")
        self.assertRuns()
        self.git("checkout", "-q", self.base, "--", CI_WORKFLOW)
        self.commit("restore ci")
        self.git("mv", CI_WORKFLOW, ".github/workflows/checks.yml")
        self.commit("rename ci")
        self.assertRuns()

    def test_another_workflow_change_skips_the_matrix(self) -> None:
        self.write(".github/workflows/testflight.yml", "name: TestFlight changed\n")
        self.write(".github/workflows/new.yml", "name: New\n")
        self.commit("workflows")
        self.assertSkips()

    def test_a_classifier_change_runs_the_matrix(self) -> None:
        self.write("Tools/ci/ci_scope.py", "print('changed')\n")
        self.commit("classifier")
        self.assertRuns()

    def test_workers_crash_tools_and_gitignore_skip_the_matrix(self) -> None:
        # The shapes of #741 (Tools/crash), #742 (GuestRelay) and #744 (AccountService).
        self.write("GuestRelay/src/relay.ts", "export const relay = 2;\n")
        self.write("GuestRelay/test/relay.test.ts", "test\n")
        self.write("AccountService/src/index.ts", "export const accounts = 2;\n")
        self.write("AccountService/wrangler.toml", "name = 'accounts'\n")
        self.write("Tools/crash/symbolicate.py", "print('changed')\n")
        self.write(".gitignore", "AccountService/node_modules/\n")
        self.commit("services")
        self.assertSkips()

    def test_a_gitignore_the_build_reads_runs_the_matrix(self) -> None:
        self.write("App/.gitignore", "*.tmp\n")
        self.commit("app gitignore")
        self.assertRuns()

    def test_other_tools_run_the_matrix(self) -> None:
        self.write("Tools/ci/ui-shard.sh", "#!/bin/sh\n")
        self.commit("shard script")
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

    def test_renaming_docs_into_code_runs_the_matrix(self) -> None:
        self.git("mv", "docs/guide.md", "App/guide.md")
        self.commit("move docs into the app")
        self.assertRuns()

    def test_renaming_a_doc_skips_the_matrix(self) -> None:
        self.git("mv", "docs/guide.md", "docs/handbook.md")
        self.commit("rename doc")
        self.assertSkips()

    def test_renames_inside_the_guest_relay_skip_the_matrix(self) -> None:
        # The shape of #746: hashed web bundle files renamed under GuestRelay/public/web.
        bundle = "export const web = 1;\n" * 40
        self.write("GuestRelay/public/web/assets/index-aaaa1111.js", bundle)
        self.commit("web bundle")
        self.base = self.git("rev-parse", "HEAD")
        self.git("mv", "GuestRelay/public/web/assets/index-aaaa1111.js", "GuestRelay/public/web/assets/index-bbbb2222.js")
        self.write("GuestRelay/public/web/assets/index-bbbb2222.js", bundle + "export const more = 2;\n")
        self.commit("new web bundle")
        self.assertSkips()

    def test_renaming_out_of_the_guest_relay_runs_the_matrix(self) -> None:
        self.git("mv", "GuestRelay/src/relay.ts", "App/relay.ts")
        self.commit("move relay into the app")
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


class NoUiPathTests(unittest.TestCase):
    def test_markdown_outside_the_build_is_docs(self) -> None:
        for path in ("README.md", "GuestRelay/README.md", "design/reference/gram/README.md", "goals/x.md"):
            self.assertTrue(is_no_ui_path(path), path)

    def test_markdown_inside_the_build_is_not_docs(self) -> None:
        for path in (
            "App/Resources/Mermaid/README.md",
            "HerdrUITests/Fixtures/PROVENANCE.md",
            "Vendor/SwiftTerm/Sources/SwiftTerm/Documentation.docc/GettingStarted.md",
        ):
            self.assertFalse(is_no_ui_path(path), path)

    def test_the_scope_jobs_workflow_and_project_are_never_no_ui_by_path(self) -> None:
        for path in (CI_WORKFLOW, "project.yml", "Tools/ci/ci_scope.py", "Tools/ci/test_ci_scope.py"):
            self.assertFalse(is_no_ui_path(path), path)
        self.assertTrue(is_no_ui_path(".github/workflows/testflight.yml"))

    def test_no_ui_prefixes_are_not_build_inputs(self) -> None:
        # GuestRelay/ and AccountService/ are Cloudflare Workers and Tools/crash/ is a Mac/Linux
        # tool: if project.yml or Package.swift ever names one, a change there can change the app.
        package = (REPO / "Package.swift").read_text()
        for prefix in NO_UI_PREFIXES:
            self.assertFalse(prefix.startswith(BUILD_DIRS), prefix)
            self.assertNotIn(prefix.rstrip("/"), PROJECT_YML, prefix)
            self.assertNotIn(prefix.rstrip("/"), package, prefix)

    def test_build_dirs_cover_every_project_source_directory(self) -> None:
        # A target added to project.yml from a new top-level directory must be added to
        # BUILD_DIRS, or Markdown it bundles would count as docs and skip the matrix.
        sources = re.findall(r"^\s*(?:- )?path: ([^\s#]+)", PROJECT_YML, flags=re.M)
        tops = {source.split("/")[0] + "/" for source in sources if source != "."}
        self.assertTrue(tops)
        self.assertEqual(sorted(tops - set(BUILD_DIRS)), [])


if __name__ == "__main__":
    unittest.main()
