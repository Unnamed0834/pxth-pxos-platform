import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))

from conftest import ROOT, load_script

ci = load_script("ci_failed_issue", "ci-failed-issue.py")
images = load_script("image_scan_issues", "image-scan-issues.py")
pr = load_script("image_scan_pr", "image-scan-pr.py")


class BotPolicyTest(unittest.TestCase):
    def test_ci_failure_policy(self):
        self.assertTrue(ci.should_open("push", "refs/heads/main"))
        self.assertFalse(ci.should_open("push", "refs/heads/other"))
        self.assertFalse(ci.should_open("pull_request", "refs/heads/main"))
        self.assertEqual(ci.failure_title("a" * 40), "CI failed: " + "a" * 40)
        self.assertEqual(ci.failure_body("job", "abc"), "action: build\nabc\njob\n")
        self.assertTrue(ci.has_open_title([{"title": "CI failed: abc"}], "CI failed: abc"))
        self.assertFalse(ci.has_open_title([{"title": "other"}], "CI failed: abc"))

    def test_image_log_parsing(self):
        a = "a" * 64
        b = "b" * 64
        c = "c" * 64
        text = "\n".join([
            "image-scan: blocked no-tag docker.io/a@sha256:" + a,
            "image-scan: blocked mystery docker.io/b@sha256:" + b,
            "image-scan: replace docker.io/a@sha256:" + a + " docker.io/a@sha256:" + c,
            "image-scan: docker.io/c@sha256:" + c,
        ])
        blocked, scanned, incomplete = images.read_log(text)
        self.assertEqual(list(blocked), ["docker.io/a"])
        self.assertEqual(blocked["docker.io/a"][0], "no-tag")
        self.assertEqual(scanned, {"docker.io/c"})
        self.assertEqual(incomplete, {"docker.io/b"})

    def test_image_issue_body(self):
        body = images.issue_body("no-tag", "docker.io/a", "ref")
        self.assertTrue(body.startswith("action: stop\nreason: no-tag\nimage: docker.io/a\nref: ref\n"))
        self.assertIn("This job does not deploy.", body)

    def test_pr_body(self):
        self.assertIn("This job does not deploy.", pr.BODY)


class SanitizationTest(unittest.TestCase):
    def test_no_internal_domains_or_private_addresses(self):
        pattern = re.compile(r"\.(?:int|internal)\.[a-z]{2,}|/home/(?!operator\b)[A-Za-z0-9_-]+")
        paths = []
        for base in ("scripts", "docs"):
            paths.extend(p for p in (ROOT / base).rglob("*") if p.is_file())
        paths.extend(ROOT / name for name in ("README.md",))
        for path in paths:
            if "__pycache__" in path.parts:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            self.assertIsNone(pattern.search(text), path.as_posix())


if __name__ == "__main__":
    unittest.main()
