import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))

from conftest import load_script

ROOT = Path(__file__).resolve().parents[2]
gate = load_script("diff_gate", "diff-gate.py")


def allow(text):
    return "#[" + text


def skip(text):
    return "pytest." + text


def diff_of(path, body):
    return (
        "diff --git a/" + path + " b/" + path + "\n"
        "--- a/" + path + "\n"
        "+++ b/" + path + "\n"
        "@@ -1,1 +1,1 @@\n"
        + body
    )


class DiffGateTest(unittest.TestCase):
    def test_removed_test(self):
        body = "-def test_price():\n+def test_other():\n"
        self.assertEqual(gate.violations(diff_of("tests/test_price.py", body)), ["removed test test_price"])

    def test_rewritten_test_is_not_a_removal(self):
        body = "-def test_price():\n+def test_price():\n     assert price == 1\n"
        self.assertEqual(gate.violations(diff_of("tests/test_price.py", body)), [])

    def test_hollow_and_gutted_tests(self):
        python = (
            "-def test_price():\n"
            "-    assert price == 1\n"
            "+def test_price():\n"
            "+    pass\n"
            " def other():\n"
        )
        rust = (
            "-fn test_price() {\n"
            "-    assert_eq!(price, 1);\n"
            "+fn test_price() {\n"
            "+    " + "todo" + "!()\n"
            " }\n"
        )
        self.assertEqual(gate.violations(diff_of("tests/test_price.py", python)), ["hollow test test_price"])
        self.assertEqual(gate.violations(diff_of("src/lib.rs", rust)), ["hollow test test_price"])
        gutted = (
            "-def test_price():\n"
            "-    assert price == 1\n"
            "+def test_price():\n"
            "+    price = 1\n"
            " def other():\n"
        )
        self.assertEqual(gate.violations(diff_of("tests/test_price.py", gutted)), ["gutted test test_price"])

    def test_unfinished_hunk_and_context_line(self):
        body = "-def test_price():\n-    assert price == 1\n+def test_price():\n+    pass\n"
        self.assertEqual(gate.violations(diff_of("tests/test_price.py", body)), [])
        context = " " + allow("allow(dead_code)]") + "\n+    let value = 1;\n"
        self.assertEqual(gate.violations(diff_of("src/lib.rs", context)), [])

    def test_added_silence(self):
        rust = diff_of("src/lib.rs", "+" + allow("allow(dead_code)]") + "\n")
        python = diff_of("tests/test_price.py", "+    " + skip("skip('later')") + "\n")
        self.assertIn("added " + allow("allow"), gate.violations(rust))
        self.assertIn("added " + skip("skip"), gate.violations(python))
        self.assertIn("added " + skip("xfail"), gate.violations(
            diff_of("tests/test_price.py", "+    " + skip("xfail('no')") + "\n")
        ))
        self.assertIn("added " + skip("mark.skip"), gate.violations(
            diff_of("tests/test_price.py", "+@" + skip("mark.skip") + "\n")
        ))

    def test_referees_and_lock_repair(self):
        workflow = "diff --git a/scripts/git-push-guard.py b/scripts/git-push-guard.py\n"
        script = "diff --git a/scripts/diff-gate.py b/scripts/diff-gate.py\n"
        table = diff_of("Cargo.toml", "+[lints.clippy]\n")
        self.assertEqual(gate.violations(workflow), ["edits referee scripts/git-push-guard.py"])
        self.assertEqual(gate.violations(script), ["edits referee scripts/diff-gate.py"])
        self.assertEqual(gate.violations(table), ["edits lint table Cargo.toml"])
        self.assertEqual(gate.violations(workflow, bootstrap=True), [])

        body = (
            "diff --git a/flake.lock b/flake.lock\n"
            "+++ b/flake.lock\n"
            "+  \"rev\": \"abc\"\n"
            "diff --git a/src/lib.rs b/src/lib.rs\n"
            "+++ b/src/lib.rs\n"
            "+" + allow("allow(clippy::all)]") + "\n"
        )
        found = gate.violations(body, lock=True)
        self.assertIn("added " + allow("allow"), found)
        self.assertIn("lock repair's only code change silences a check", found)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            repo.mkdir()
            subprocess.check_call(["git", "-C", str(repo), "init", "-q"])
            subprocess.check_call(["git", "-C", str(repo), "config", "user.email", "t@example.com"])
            subprocess.check_call(["git", "-C", str(repo), "config", "user.name", "test"])
            (repo / "src").mkdir()
            (repo / "src" / "lib.rs").write_text("fn test_price() {}\n")
            subprocess.check_call(["git", "-C", str(repo), "add", "."])
            subprocess.check_call(["git", "-C", str(repo), "commit", "-qm", "base"])
            subprocess.check_call(["git", "-C", str(repo), "branch", "-M", "main"])
            subprocess.check_call(["git", "-C", str(repo), "checkout", "-qb", "change/issue-1"])
            (repo / "src" / "lib.rs").write_text("fn test_other() {}\n")
            subprocess.check_call(["git", "-C", str(repo), "commit", "-qam", "rename"])
            proc = subprocess.run(
                ["python3", str(ROOT / "scripts" / "diff-gate.py"), "--repo", str(repo),
                 "--base", "main", "--head", "HEAD"],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(proc.returncode, 1)
            self.assertEqual(proc.stdout.strip(), "removed test test_price")


if __name__ == "__main__":
    unittest.main()
