#!/usr/bin/env python3

import os
import re
import subprocess
import sys

MARKERS = ("networking.firewall", "networking.nftables", "openFirewall")


def code_head(line):
    return line.split("#", 1)[0]


def starts_policy(line):
    head = code_head(line)
    return any(marker in head for marker in MARKERS)


def statement_end(lines, start):
    text = "\n".join(lines[start:])
    index = 0
    limit = len(text)
    depth_brace = 0
    depth_paren = 0
    in_str = None
    while index < limit:
        if in_str is None and text.startswith("''", index):
            in_str = "''"
            index += 2
            continue
        if in_str == "''":
            if text.startswith("'''", index):
                index += 3
                continue
            if text.startswith("''", index):
                in_str = None
                index += 2
                continue
            index += 1
            continue
        if in_str is None and text[index] == '"':
            in_str = '"'
            index += 1
            continue
        if in_str == '"':
            if text[index] == "\\":
                index += 2
                continue
            if text[index] == '"':
                in_str = None
            index += 1
            continue
        char = text[index]
        if char == "{":
            depth_brace += 1
        elif char == "}":
            depth_brace = max(0, depth_brace - 1)
        elif char == "(":
            depth_paren += 1
        elif char == ")":
            depth_paren = max(0, depth_paren - 1)
        elif char == ";" and depth_brace == 0 and depth_paren == 0:
            return start + text[: index + 1].count("\n")
        index += 1
    return len(lines) - 1


def policy_lines(text):
    lines = text.splitlines()
    marked = set()
    index = 0
    while index < len(lines):
        if starts_policy(lines[index]):
            end = statement_end(lines, index)
            for number in range(index, end + 1):
                marked.add(number + 1)
            index = end + 1
            continue
        index += 1
    return marked


def policy_text(text):
    lines = text.splitlines()
    marked = policy_lines(text)
    return "\n".join(lines[number - 1] for number in sorted(marked))


def denied_path(path):
    norm = path.replace("\\", "/").lstrip("./")
    if norm == "secrets" or norm.startswith("secrets/"):
        return "secrets/"
    if norm == "hosts/owners.conf":
        return "hosts/owners.conf"
    if norm == "secrets/identity.age" or norm.endswith("/secrets/identity.age"):
        return "identity.age"
    if norm == "secrets/identity.pub" or norm.endswith("/secrets/identity.pub"):
        return "identity.pub"
    if norm == "modules/plugins/firewall.nix":
        return "modules/plugins/firewall.nix"
    return None


def safe_branch(name):
    if not name or name.startswith("-") or name.startswith("/"):
        return False
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", name):
        return False
    return all(part not in ("", ".", "..") for part in name.split("/"))


def _verify(ref):
    proc = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", ref],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return proc.returncode == 0


def resolve_base(name):
    for ref in (f"refs/remotes/origin/{name}", f"refs/heads/{name}"):
        if _verify(ref):
            return ref
    proc = subprocess.run(
        [
            "git",
            "fetch",
            "--depth",
            "1",
            "origin",
            f"refs/heads/{name}:refs/remotes/origin/{name}",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    ref = f"refs/remotes/origin/{name}"
    if proc.returncode != 0 or not _verify(ref):
        print("security-scan: could not read the default branch", file=sys.stderr)
        raise SystemExit(1)
    return ref


def _merge_base(ref):
    proc = subprocess.run(
        ["git", "merge-base", ref, "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    sha = proc.stdout.strip()
    if proc.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", sha):
        return sha
    return None


def left_commit(ref):
    found = _merge_base(ref)
    if found:
        return found
    subprocess.run(
        ["git", "fetch", "--unshallow", "origin"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    found = _merge_base(ref)
    if found:
        return found
    proc = subprocess.run(
        ["git", "rev-parse", "--verify", ref],
        capture_output=True,
        text=True,
        check=False,
    )
    sha = proc.stdout.strip()
    if proc.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        print("security-scan: could not resolve the default branch", file=sys.stderr)
        raise SystemExit(1)
    print(
        "security-scan: no merge base, comparing against the default branch tip",
        file=sys.stderr,
    )
    return sha


def changed_paths(left):
    proc = subprocess.run(
        ["git", "diff", "--name-status", "-z", "--find-renames", left, "HEAD"],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        print("security-scan: diff failed", file=sys.stderr)
        raise SystemExit(1)
    parts = proc.stdout.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    found = []
    index = 0
    while index < len(parts):
        status = parts[index].decode("utf-8", errors="replace")
        index += 1
        if not status:
            continue
        if status[0] in ("R", "C"):
            if index + 1 >= len(parts):
                print("security-scan: truncated rename record", file=sys.stderr)
                raise SystemExit(1)
            old = parts[index].decode("utf-8", errors="replace")
            new = parts[index + 1].decode("utf-8", errors="replace")
            index += 2
            found.append((old, new))
            continue
        if index >= len(parts):
            print("security-scan: truncated diff record", file=sys.stderr)
            raise SystemExit(1)
        path = parts[index].decode("utf-8", errors="replace")
        index += 1
        found.append((path, path))
    return found


def blob(rev, path):
    proc = subprocess.run(
        ["git", "show", f"{rev}:{path}"],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout.decode("utf-8", errors="replace")


def main():
    event = os.environ.get("GITHUB_EVENT_NAME") or os.environ.get("FORGEJO_EVENT_NAME") or ""
    if event != "pull_request":
        print("security-scan: not a pull request, not diffing secrets or the firewall")
        return 0
    base = os.environ.get("GITHUB_BASE_REF") or ""
    if not safe_branch(base):
        print("security-scan: pull request base ref is missing", file=sys.stderr)
        return 1
    ref = resolve_base(base)
    left = left_commit(ref)
    failed = False
    reported = set()
    for old, new in changed_paths(left):
        paths = list(dict.fromkeys((old, new)))
        if any(denied_path(path) for path in paths):
            for path in paths:
                reason = denied_path(path)
                if reason and path not in reported:
                    print(f"security-scan: {path} ({reason})", file=sys.stderr)
                    reported.add(path)
            failed = True
            continue
        before = policy_text(blob(left, old))
        after = policy_text(blob("HEAD", new))
        if before != after:
            shown = new if new == old else f"{old} -> {new}"
            print(f"security-scan: firewall policy changed in {shown}", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print("security-scan: pull request diff does not touch secrets, owner keys, or the firewall")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
