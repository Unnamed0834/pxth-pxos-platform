import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release-verify.sh"
PATH_OK = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test"
REV = "0123456789abcdef0123456789abcdef01234567"


def make_key(directory, name):
    path = Path(directory) / name
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-f", str(path), "-N", "", "-C", "release-test"],
        check=True,
    )
    return path, path.with_suffix(".pub").read_text().strip()


def sign(key, store_path, rev):
    result = subprocess.run(
        [str(SCRIPT), "sign", "--key", str(key), "--path", store_path, "--rev", rev],
        text=True, capture_output=True, check=True,
    )
    token = result.stdout.strip()
    assert token and "\n" not in token and "PRIVATE" not in token
    return token


def verify(public, store_path, rev, token):
    return subprocess.run(
        [str(SCRIPT), "verify", "--public-key", public, "--path", store_path,
         "--rev", rev, "--signature", token],
        text=True, capture_output=True, check=False,
    )


class ReleaseVerifyTest(unittest.TestCase):
    def test_valid_signature_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            key, public = make_key(tmp, "release")
            token = sign(key, PATH_OK, REV)
            result = verify(public, PATH_OK, REV, token)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_tampered_path_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            key, public = make_key(tmp, "release")
            token = sign(key, PATH_OK, REV)
            tampered = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-test"
            self.assertNotEqual(verify(public, tampered, REV, token).returncode, 0)

    def test_tampered_rev_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            key, public = make_key(tmp, "release")
            token = sign(key, PATH_OK, REV)
            other = "fedcba9876543210fedcba9876543210fedcba98"
            self.assertNotEqual(verify(public, PATH_OK, other, token).returncode, 0)

    def test_wrong_key_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            key, _public = make_key(tmp, "release")
            _other, other_public = make_key(tmp, "other")
            token = sign(key, PATH_OK, REV)
            self.assertNotEqual(verify(other_public, PATH_OK, REV, token).returncode, 0)

    def test_bad_inputs_refused(self):
        bad = subprocess.run(
            [str(SCRIPT), "sign", "--key", "/nonexistent", "--path", "/tmp/not-a-store-path", "--rev", REV],
            text=True, capture_output=True, check=False,
        )
        self.assertNotEqual(bad.returncode, 0)


if __name__ == "__main__":
    unittest.main()
