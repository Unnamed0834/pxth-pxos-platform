import io
import json
import os
import sys
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(__file__))

from conftest import load_script

api = load_script("forgejo_api", "forgejo_api.py")


class Response:
    def __init__(self, payload, status=200):
        self.status = status
        self._raw = b"" if payload is None else json.dumps(payload).encode()

    def read(self):
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


class Transport:
    def __init__(self, pages):
        self.pages = list(pages)
        self.calls = []

    def __call__(self, req, timeout=None):
        self.calls.append((req.get_method(), req.full_url, req.data))
        answer = self.pages.pop(0)
        if isinstance(answer, Exception):
            raise answer
        status, payload = answer
        return Response(payload, status)


class ForgejoApiTest(unittest.TestCase):
    def setUp(self):
        self.real_urlopen = api.urllib.request.urlopen

    def tearDown(self):
        api.urllib.request.urlopen = self.real_urlopen

    def use(self, transport):
        api.urllib.request.urlopen = transport
        return transport

    def test_pagination(self):
        transport = self.use(Transport([(200, [{"number": n} for n in range(50)]), (200, [{"number": 50}])]))
        client = api.Client("https://git.example.com/", "org/repo", "token")
        found = client.issues()
        self.assertEqual(len(found), 51)
        self.assertEqual([call[0] for call in transport.calls], ["GET", "GET"])
        self.assertEqual([call[1].rsplit("page=", 1)[1] for call in transport.calls], ["1", "2"])
        self.assertTrue(transport.calls[0][1].startswith("https://git.example.com/api/v1/repos/org/repo/issues"))

    def test_http_error_mapping(self):
        http = urllib.error.HTTPError("u", 503, "down", {}, io.BytesIO(b"down"))
        self.use(Transport([http]))
        client = api.Client("https://git.example.com", "org/repo", "token")
        with self.assertRaises(api.ForgejoError) as caught:
            client.request("GET", "/issues", action="list")
        self.assertEqual(caught.exception.status, 503)
        self.assertEqual(caught.exception.action, "list")
        self.assertIn("503", str(caught.exception))

    def test_url_error_mapping(self):
        self.use(Transport([urllib.error.URLError("offline")]))
        client = api.Client("https://git.example.com", "org/repo", "token")
        with self.assertRaises(api.ForgejoError) as caught:
            client.request("GET", "/issues", action="list")
        self.assertIsNone(caught.exception.status)
        self.assertEqual(str(caught.exception), "list request failed")

    def test_writes(self):
        transport = self.use(
            Transport([(201, {"number": 9}), (200, None), (200, None), (201, {"number": 3})])
        )
        client = api.Client("https://git.example.com", "org/repo", "token")
        self.assertEqual(client.open_issue("title", "body"), 9)
        client.update_issue(9, body="new", state="open")
        client.close_issue(9)
        status, payload = client.create_pull("pr", "branch", "main", "body")
        self.assertEqual(status, 201)
        self.assertEqual(payload, {"number": 3})
        self.assertEqual([call[0] for call in transport.calls], ["POST", "PATCH", "PATCH", "POST"])
        self.assertEqual(json.loads(transport.calls[2][2]), {"state": "closed"})
        self.assertEqual(json.loads(transport.calls[3][2])["base"], "main")

    def test_issue_filters(self):
        rows = [{"title": "Image pin blocked: a"}, {"title": "other"}]
        self.use(Transport([(200, rows), (200, rows)]))
        client = api.Client("https://git.example.com", "org/repo", "token")
        self.assertEqual(client.issues_with_prefix("Image pin blocked: "), {"a": {"title": "Image pin blocked: a"}})
        self.assertEqual(client.issues_with_title("other"), [{"title": "other"}])


if __name__ == "__main__":
    unittest.main()
