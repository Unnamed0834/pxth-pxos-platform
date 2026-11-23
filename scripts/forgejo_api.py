#!/usr/bin/env python3

import json
import urllib.error
import urllib.request


class ForgejoError(Exception):

    def __init__(self, message, status=None, action=""):
        super().__init__(message)
        self.status = status
        self.action = action


class Client:

    def __init__(self, origin, repo, token, max_pages=20):
        self.base = origin.rstrip("/") + "/api/v1/repos/" + repo
        self.headers = {
            "Authorization": "token " + token,
            "Content-Type": "application/json",
        }
        self.max_pages = max_pages

    def request(self, method, path, payload=None, action="request"):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(
            self.base + path,
            data=data,
            method=method,
            headers=self.headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                status = resp.status
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            message = f"{action} failed: {exc.code} {detail}".rstrip()
            raise ForgejoError(message, status=exc.code, action=action) from None
        except urllib.error.URLError:
            raise ForgejoError(f"{action} request failed", action=action) from None
        return status, (json.loads(raw) if raw else None)

    def issues(self, state="open", action="list"):
        found = []
        for page in range(1, self.max_pages + 1):
            _status, batch = self.request(
                "GET",
                f"/issues?state={state}&type=issues&limit=50&page={page}",
                action=action,
            )
            if not isinstance(batch, list):
                raise ForgejoError("issue list is malformed", action=action)
            found.extend(batch)
            if len(batch) < 50:
                break
        return found

    def issues_with_title(self, title, action="list"):
        return [item for item in self.issues(action=action) if item.get("title") == title]

    def issues_with_prefix(self, prefix, action="list"):
        found = {}
        for item in self.issues(action=action):
            title = item.get("title") or ""
            if title.startswith(prefix):
                found[title[len(prefix) :]] = item
        return found

    def open_issue(self, title, body, action="create"):
        _status, created = self.request(
            "POST", "/issues", {"title": title, "body": body}, action=action
        )
        return created.get("number") if isinstance(created, dict) else None

    def update_issue(self, number, **fields):
        self.request("PATCH", "/issues/" + str(number), fields, action="update")

    def close_issue(self, number):
        self.update_issue(number, state="closed")

    def create_pull(self, title, head, base, body):
        return self.request(
            "POST",
            "/pulls",
            {"title": title, "head": head, "base": base, "body": body},
            action="pull request",
        )
