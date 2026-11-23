
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from forgejo_api import Client, ForgejoError  # noqa: E402

ORIGIN = "https://git.example.com"
REPO = "example/paxos"


def event_name():
    return os.environ.get("GITHUB_EVENT_NAME") or os.environ.get("FORGEJO_EVENT_NAME") or ""


def should_open(event, ref):
    return event == "push" and ref == "refs/heads/main"


def failure_title(sha):
    return "CI failed: " + sha


def failure_body(context, sha):
    return "action: build\n" + sha + "\n" + context + "\n"


def has_open_title(issues, title):
    return any(isinstance(issue, dict) and issue.get("title") == title for issue in issues)


def main():
    if not should_open(event_name(), os.environ.get("GITHUB_REF") or ""):
        print("ci-failed-issue: not a push to main")
        return 0
    context = os.environ.get("CI_FAIL_CONTEXT") or ""
    sha = os.environ.get("GITHUB_SHA") or ""
    if not context or "\n" in context or "\r" in context or not re.fullmatch(r"[0-9a-f]{40}", sha):
        print("ci-failed-issue: missing context or sha", file=sys.stderr)
        return 1
    token = (os.environ.get("CI_ISSUE_TOKEN") or "").strip()
    if not token:
        print("ci-failed-issue: CI_ISSUE_TOKEN is empty", file=sys.stderr)
        return 1
    title = failure_title(sha)
    client = Client(ORIGIN, REPO, token)
    try:
        issues = client.issues(action="list")
    except ForgejoError as exc:
        if exc.status is not None:
            print(f"ci-failed-issue: list failed {exc.status}", file=sys.stderr)
        else:
            print(f"ci-failed-issue: {exc}", file=sys.stderr)
        return 1
    if has_open_title(issues, title):
        print("ci-failed-issue: already open")
        return 0
    try:
        number = client.open_issue(title, failure_body(context, sha), action="create")
    except ForgejoError as exc:
        if exc.status is not None:
            print(f"ci-failed-issue: create failed {exc.status}", file=sys.stderr)
        else:
            print(f"ci-failed-issue: {exc}", file=sys.stderr)
        return 1
    print("ci-failed-issue: opened " + str(number))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
