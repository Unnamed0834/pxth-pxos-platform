import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

from conftest import load_script

guard = load_script("git_push_guard", "git-push-guard.py")


class GitPushGuardTest(unittest.TestCase):
    def test_decide(self):
        branch = "change/issue-85"
        self.assertEqual(guard.decide(branch, set(), {branch}, True), "refuse")
        self.assertEqual(guard.decide(branch, {branch}, {branch}, True), "allow")
        self.assertEqual(guard.decide(branch, set(), set(), True), "allow")
        self.assertEqual(guard.decide(branch, set(), set(), False), "refuse")
        self.assertEqual(guard.decide("feature", set(), {"feature"}, True), "allow")
        self.assertEqual(guard.decide("lock/flake-example", set(), {"lock/flake-example"}, True), "refuse")

    def test_classify(self):
        self.assertEqual(guard.classify(["status"], "main"), ("exec", []))
        self.assertEqual(guard.classify(["credential", "fill"], "main"), ("cred", []))
        self.assertEqual(guard.classify(["push", "--all"], "main"), ("all", []))
        self.assertEqual(guard.classify(["push", "origin", "HEAD"], "change/issue-4"), ("push", ["change/issue-4"]))
        self.assertEqual(
            guard.classify(["-C", "repo", "push", "origin", "HEAD:lock/flake-1"], "main"),
            ("push", ["lock/flake-1"]),
        )
        self.assertEqual(guard.classify(["push"], "image/cve-1"), ("push", ["image/cve-1"]))

    def test_repo_of(self):
        self.assertEqual(
            guard.repo_of("https://git.example.com/example/paxos.git"),
            ("https://git.example.com", "example", "paxos"),
        )
        self.assertEqual(
            guard.repo_of("https://user:secret@git.example.com/example/paxos.git"),
            ("https://git.example.com", "example", "paxos"),
        )
        self.assertIsNone(guard.repo_of("not a url"))

    def test_branches_of(self):
        pulls = [{"head": {"ref": "change/issue-1"}}, {"head": {"ref": "lock/flake-1"}}, {}]
        self.assertEqual(guard.branches_of(pulls), {"change/issue-1", "lock/flake-1"})

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
        self.assertEqual(guard.token_for(document, "git.example.com"), "value")
        self.assertIsNone(guard.token_for(document, "other.example.com"))


if __name__ == "__main__":
    unittest.main()
