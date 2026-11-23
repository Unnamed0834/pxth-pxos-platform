import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

from conftest import load_script

mod = load_script("pr_sensitive_diff", "pr-sensitive-diff.py")


class PrSensitiveDiffTest(unittest.TestCase):
    def test_denied_paths(self):
        cases = {
            "secrets": "secrets/",
            "secrets/shared/token": "secrets/",
            "hosts/owners.conf": "hosts/owners.conf",
            "hosts/bsn/secrets/identity.age": "identity.age",
            "hosts/bsn/secrets/identity.pub": "identity.pub",
            "modules/plugins/firewall.nix": "modules/plugins/firewall.nix",
        }
        for path, reason in cases.items():
            self.assertEqual(mod.denied_path(path), reason, path)
        for path in ("README.md", "modules/core/ssh.nix", "scripts/deploy.sh"):
            self.assertIsNone(mod.denied_path(path), path)

    def test_policy_lines(self):
        text = "\n".join([
            "  environment.systemPackages = [ pkgs.hello ];",
            "  networking.firewall.allowedTCPPorts = [ 22 ];",
            "    ++ [ 443 ];",
            "  services.sshd.enable = true;",
            "  networking.nftables.tables = {};",
            "  services.openssh.openFirewall = true;",
        ])
        marked = mod.policy_lines(text)
        self.assertEqual(marked, {2, 5, 6})
        self.assertIn("allowedTCPPorts", mod.policy_text(text))
        self.assertNotIn("systemPackages", mod.policy_text(text))

    def test_statement_end_with_strings(self):
        lines = [
            "  x = ''",
            "  networking.firewall.allowedTCPPorts = [ 22 ];",
            "  '';",
            "  y = 1;",
        ]
        self.assertEqual(mod.statement_end(lines, 0), 2)

    def test_safe_branch(self):
        for name in ("main", "feature/x", "lock/flake-example"):
            self.assertTrue(mod.safe_branch(name), name)
        for name in ("", "-bad", "/bad", "../bad", "bad name"):
            self.assertFalse(mod.safe_branch(name), name)


if __name__ == "__main__":
    unittest.main()
