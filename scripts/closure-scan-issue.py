#!/usr/bin/env python3

import json
import re
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from forgejo_api import Client, ForgejoError  # noqa: E402

TITLE = "Closure scan: node-02"


def decision(text, rc):
    if "not in the store" in text or "refusing to build" in text:
        return "skip"
    if rc == 0:
        return "close"
    return "open"


def issue_body(text, rev):
    lines = [line for line in text.splitlines() if line.startswith("closure-scan:")]
    body = "action: stop\n"
    if rev:
        body += rev + "\n"
    if lines:
        body += "\n".join(lines[:40]) + "\n"
    return body


def token_for(document, host):
    instances = document.get("providers", {}).get("forgejo", {}).get("instances", {})
    for raw, inst in instances.items():
        if urllib.parse.urlparse(raw).hostname != host:
            continue
        wanted = inst.get("activeCredentialId")
        for cred in inst.get("credentials") or []:
            if cred.get("credentialId") != wanted:
                continue
            if cred.get("status") not in (None, "", "valid"):
                continue
            return cred.get("token") or ""
    return ""


def apply(text, rc, rev, opener, closer):
    choice = decision(text, rc)
    if choice == "skip":
        return "skip"
    if choice == "close":
        closer()
        return "close"
    opener(issue_body(text, rev))
    return "open"


def main(argv):
    if len(argv) not in (6, 7):
        raise SystemExit(
            "usage: closure-scan-issue.py ORIGIN REPO CRED LOG RC [REV]"
        )
    origin, repo, cred, log, rc_text = argv[1:6]
    rev = argv[6].strip() if len(argv) == 7 else ""
    if rev and re.fullmatch(r"[0-9a-f]{40}", rev) is None:
        rev = ""
    origin = origin.rstrip("/")
    if not origin.startswith("https://"):
        raise SystemExit("closure-scan-issue: bad origin")
    host = urllib.parse.urlparse(origin).hostname or ""
    try:
        rc = int(rc_text)
    except ValueError:
        raise SystemExit("closure-scan-issue: bad exit code") from None
    text = Path(log).read_text(encoding="utf-8", errors="replace")
    document = json.loads(Path(cred).read_text())
    token = token_for(document, host)
    if not token:
        raise SystemExit("closure-scan-issue: no forgejo token")
    client = Client(origin, repo, token)

    def opener(body):
        matches = client.issues_with_title(TITLE)
        if matches:
            number = matches[0].get("number")
            client.update_issue(number, body=body)
            print("closure-scan: updated issue " + str(number))
            return
        number = client.open_issue(TITLE, body)
        print("closure-scan: opened issue " + str(number))

    def closer():
        for item in client.issues_with_title(TITLE):
            number = item.get("number")
            client.close_issue(number)
            print("closure-scan: closed issue " + str(number))

    try:
        choice = apply(text, rc, rev, opener, closer)
    except ForgejoError as exc:
        if exc.status is not None:
            raise SystemExit("closure-scan-issue: request failed: " + str(exc.status)) from None
        raise SystemExit("closure-scan-issue: request failed") from None
    if choice == "open":
        return
    print("closure-scan: " + choice)


if __name__ == "__main__":
    main(sys.argv)
