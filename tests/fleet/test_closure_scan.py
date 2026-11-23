import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

from conftest import load_script

mod = load_script("closure_scan_issue", "closure-scan-issue.py")


class ClosureScanIssueTest(unittest.TestCase):
    def test_decision(self):
        self.assertEqual(mod.decision("store path not in the store", 1), "skip")
        self.assertEqual(mod.decision("refusing to build", 1), "skip")
        self.assertEqual(mod.decision("closure-scan: ok", 0), "close")
        self.assertEqual(mod.decision("closure-scan: FAIL", 1), "open")

    def test_issue_body(self):
        text = "noise\nclosure-scan: FAIL one\nclosure-scan: FAIL two\n"
        body = mod.issue_body(text, "abc123")
        self.assertTrue(body.startswith("action: stop\nabc123\n"))
        self.assertIn("closure-scan: FAIL one", body)
        self.assertIn("closure-scan: FAIL two", body)
        self.assertNotIn("noise", body)

    def test_token_for(self):
        document = {
            "providers": {
                "forgejo": {
                    "instances": {
                        "https://git.example.com": {
                            "activeCredentialId": "one",
                            "credentials": [
                                {"credentialId": "one", "token": "value", "status": "valid"},
                            ],
                        }
                    }
                }
            }
        }
        self.assertEqual(mod.token_for(document, "git.example.com"), "value")
        self.assertEqual(mod.token_for(document, "other.example.com"), "")

    def test_apply(self):
        calls = []
        self.assertEqual(mod.apply("not in the store", 1, "", lambda b: calls.append("open"), lambda: calls.append("close")), "skip")
        self.assertEqual(mod.apply("ok", 0, "", lambda b: calls.append("open"), lambda: calls.append("close")), "close")
        self.assertEqual(mod.apply("FAIL", 1, "rev", lambda b: calls.append("open"), lambda: calls.append("close")), "open")
        self.assertEqual(calls, ["close", "open"])


if __name__ == "__main__":
    unittest.main()
