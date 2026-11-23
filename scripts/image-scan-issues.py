#!/usr/bin/env python3

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from forgejo_api import Client, ForgejoError  # noqa: E402

ORIGIN = "https://git.example.com"

REASONS = {
    "no-tag": (
        "No tag is pinned, so the scan cannot see a newer build. "
        "Write the tag in the Nix file before a digest can move."
    ),
    "tag-unchanged": (
        "The tag still points at this digest. Upstream has not "
        "published a new build."
    ),
    "candidate-still-vulnerable": (
        "The tag points at a newer digest, and that digest still "
        "has medium or higher findings."
    ),
    "unfixed": (
        "These findings have no published fix in a newer build "
        "of this tag."
    ),
}


def read_log(text):
    blocked = {}
    scanned = set()
    incomplete = set()
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("image-scan: blocked "):
            rest = line[len("image-scan: blocked ") :]
            reason, ref = rest.split(" ", 1)
            image = ref.split("@", 1)[0]
            if reason not in REASONS:
                incomplete.add(image)
                continue
            blocked[image] = (reason, ref.split()[0])
        elif line.startswith("image-scan: ") and line.count(" ") == 1 and "@sha256:" in line:
            ref = line.split(" ", 1)[1]
            scanned.add(ref.split("@", 1)[0])
    return blocked, scanned, incomplete


def issue_body(reason, image, ref):
    return (
        f"action: stop\nreason: {reason}\nimage: {image}\nref: {ref}\n\n"
        f"{REASONS[reason]} This job does not deploy.\n"
    )


def apply(client, prefix, blocked, scanned, incomplete):
    open_issues = client.issues_with_prefix(prefix, action="list")
    for image, (reason, ref) in sorted(blocked.items()):
        body = issue_body(reason, image, ref)
        existing = open_issues.get(image)
        if existing is None:
            number = client.open_issue(prefix + image, body, action="create")
            print(f"image-scan: opened issue {number} {image}")
        else:
            number = existing.get("number")
            client.update_issue(number, body=body)
            print(f"image-scan: updated issue {number} {image}")
    for image, issue in sorted(open_issues.items()):
        if image in blocked or image in incomplete or image not in scanned:
            continue
        number = issue.get("number")
        client.close_issue(number)
        print(f"image-scan: closed issue {number} {image}")


def main():
    repo = os.environ["REPO"]
    token = (os.environ.get("LOCK_TOKEN") or "").strip()
    if not token:
        raise SystemExit("image-scan: FLAKE_LOCK is empty")
    prefix = os.environ.get("IMAGE_ISSUE_PREFIX", "Image pin blocked: ")
    text = Path(os.environ["SCAN_LOG"]).read_text(encoding="utf-8", errors="replace")
    client = Client(ORIGIN, repo, token)
    try:
        apply(client, prefix, *read_log(text))
    except ForgejoError as exc:
        raise SystemExit(f"image-scan: issue api failed: {exc}") from None


if __name__ == "__main__":
    main()
