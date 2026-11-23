#!/usr/bin/env python3

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from forgejo_api import Client, ForgejoError  # noqa: E402

ORIGIN = "https://git.example.com"

BODY = (
    "Pinned tags moved to a digest that no longer contains "
    "the fixed medium or higher CVEs. CI runs on this pull "
    "request. This job does not deploy."
)


def main():
    repo = os.environ["REPO"]
    token = (os.environ.get("LOCK_TOKEN") or "").strip()
    if not token:
        raise SystemExit("image-scan: FLAKE_LOCK is empty")
    branch = os.environ["BRANCH"]
    title = os.environ["IMAGE_PR_TITLE"]
    client = Client(ORIGIN, repo, token)
    try:
        status, payload = client.create_pull(title, branch, "main", BODY)
    except ForgejoError as exc:
        if exc.status == 409:
            print("image-scan: pull request already open")
            return
        raise SystemExit(f"image-scan: pull request failed: {exc}") from None
    number = payload.get("number") if isinstance(payload, dict) else None
    print(f"image-scan: opened pull request {number} ({status})")


if __name__ == "__main__":
    main()
