#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CRED = Path("/run/job-cred/source-control-auth.json")
REAL = "/usr/libexec/paxos-git"
GUARDED = ("change/issue-", "lock/flake-", "image/cve-")
TAKES = {"-o", "--push-option", "--repo", "--exec", "--receive-pack", "--recurse-submodules"}
GLOBAL_TAKES = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"}
TRACE = (
    "GIT_TRACE",
    "GIT_TRACE_CURL",
    "GIT_CURL_VERBOSE",
    "GIT_TRACE_PACKET",
    "GIT_TRACE_PERFORMANCE",
    "GIT_TRACE_SETUP",
)


def split_git(argv):
    repo = None
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            index += 1
            break
        if arg in GLOBAL_TAKES:
            if arg == "-C" and index + 1 < len(argv):
                repo = argv[index + 1]
            index += 2
            continue
        if arg.startswith("--git-dir=") or arg.startswith("--work-tree=") or arg.startswith("--namespace="):
            index += 1
            continue
        if arg.startswith("-C"):
            repo = arg[2:] if len(arg) > 2 else repo
            index += 1
            continue
        if arg.startswith("-c") and arg != "-c":
            index += 1
            continue
        if arg.startswith("-"):
            index += 1
            continue
        break
    sub = argv[index] if index < len(argv) else ""
    return repo, sub, argv[index + 1 :]


def push_positionals(rest):
    found = []
    index = 0
    while index < len(rest):
        arg = rest[index]
        if arg == "--":
            found.extend(rest[index + 1 :])
            break
        if arg in ("--all", "--mirror"):
            return None
        if arg in TAKES:
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        found.append(arg)
        index += 1
    return found


def destination_branches(positionals, current):
    if positionals is None:
        return None
    args = list(positionals)
    if args and ":" not in args[0] and "/" not in args[0] and args[0] != "HEAD":
        args = args[1:]
    if not args:
        return [current] if current else []
    found = []
    for spec in args:
        if spec == "HEAD":
            if current:
                found.append(current)
            continue
        dest = spec.split(":", 1)[1] if ":" in spec else spec
        if dest.startswith("+"):
            dest = dest[1:]
        if dest.startswith("refs/heads/"):
            dest = dest[len("refs/heads/") :]
        if dest == "":
            src = spec.split(":", 1)[0]
            if src.startswith("+"):
                src = src[1:]
            if src.startswith("refs/heads/"):
                src = src[len("refs/heads/") :]
            dest = src
        if dest:
            found.append(dest)
    return found


def guarded(branch):
    return any(branch.startswith(prefix) for prefix in GUARDED)


def decide(branch, open_refs, closed_refs, listed):
    if not branch or not guarded(branch):
        return "allow"
    if not listed:
        return "refuse"
    if branch in open_refs:
        return "allow"
    if branch in closed_refs:
        return "refuse"
    return "allow"


def classify(argv, current):
    _repo, sub, rest = split_git(argv)
    if sub == "credential":
        return "cred", []
    if sub != "push":
        return "exec", []
    positionals = push_positionals(rest)
    if positionals is None:
        return "all", []
    return "push", destination_branches(positionals, current)


def branches_of(pulls):
    found = set()
    for pull in pulls or []:
        if not isinstance(pull, dict):
            continue
        ref = ((pull.get("head") or {}).get("ref")) or ""
        if isinstance(ref, str) and ref:
            found.add(ref)
    return found


def token_for(document, host):
    if not isinstance(document, dict):
        return None
    instances = ((document.get("providers") or {}).get("forgejo") or {}).get("instances") or {}
    if not isinstance(instances, dict):
        return None
    for raw, inst in instances.items():
        if not isinstance(raw, str) or not isinstance(inst, dict):
            continue
        if urllib.parse.urlparse(raw).hostname != host:
            continue
        wanted = inst.get("activeCredentialId")
        cred = next(
            (item for item in (inst.get("credentials") or []) if isinstance(item, dict) and item.get("credentialId") == wanted),
            None,
        )
        if cred is None or cred.get("status") not in (None, "", "valid"):
            return None
        token = cred.get("token") or ""
        if not isinstance(token, str) or not token or any(ch in token for ch in "\n\r"):
            return None
        return token
    return None


def repo_of(remote):
    parsed = urllib.parse.urlparse((remote or "").strip())
    if parsed.scheme not in ("https", "http") or not parsed.hostname:
        return None
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) != 2:
        return None
    owner, name = parts
    if name.endswith(".git"):
        name = name[: -len(".git")]
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", owner) or not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", name):
        return None
    origin = parsed.scheme + "://" + parsed.hostname
    if parsed.port:
        origin += ":" + str(parsed.port)
    return origin, owner, name


def list_pulls(origin, owner, name, state, token, opener):
    found = []
    page = 1
    while page <= 3:
        url = (
            origin
            + "/api/v1/repos/"
            + owner
            + "/"
            + name
            + "/pulls?state="
            + state
            + "&limit=50&page="
            + str(page)
        )
        req = urllib.request.Request(url, headers={"Authorization": "token " + token, "Accept": "application/json"})
        try:
            with opener(req, timeout=30) as resp:
                batch = json.loads(resp.read() or b"[]")
        except (urllib.error.URLError, TimeoutError, ValueError, json.JSONDecodeError):
            return None
        if not isinstance(batch, list):
            return None
        found.extend(batch)
        if len(batch) < 50:
            break
        page += 1
    return found


def exec_git(argv):
    for key in TRACE:
        os.environ.pop(key, None)
    for path in ("/usr/lib/git-core", "/usr/libexec/git-core"):
        if os.path.isdir(path):
            os.environ["GIT_EXEC_PATH"] = path
            break
    os.execv(REAL, [REAL, *argv])


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    kind, branches = classify(argv, "")
    if kind == "cred":
        print("git-cred: refused", file=sys.stderr)
        return 1
    if kind == "all":
        print("git-push: refusing --all", file=sys.stderr)
        return 1
    if kind != "push":
        exec_git(argv)
        return 0
    repo, _sub, _rest = split_git(argv)
    cmd = [REAL, "-C", repo] if repo else [REAL]
    try:
        current = subprocess.check_output(
            cmd + ["rev-parse", "--abbrev-ref", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, OSError):
        current = ""
    kind, branches = classify(argv, current)
    watched = [branch for branch in branches if guarded(branch)] if kind == "push" else []
    if not watched:
        exec_git(argv)
        return 0
    try:
        remote = subprocess.check_output(
            cmd + ["remote", "get-url", "origin"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, OSError):
        remote = ""
    parsed = repo_of(remote)
    try:
        document = json.loads(CRED.read_text())
    except (OSError, json.JSONDecodeError):
        document = None
    token = token_for(document, parsed[0].split("://", 1)[1].split(":", 1)[0]) if parsed else None
    if parsed is None or not token:
        print("git-push: could not read the pull request", file=sys.stderr)
        return 1
    origin, owner, name = parsed
    open_rows = list_pulls(origin, owner, name, "open", token, urllib.request.urlopen)
    closed_rows = list_pulls(origin, owner, name, "closed", token, urllib.request.urlopen)
    listed = open_rows is not None and closed_rows is not None
    open_refs = branches_of(open_rows)
    closed_refs = branches_of(closed_rows)
    for branch in watched:
        if decide(branch, open_refs, closed_refs, listed) == "refuse":
            print("git-push: pull request is closed", file=sys.stderr)
            return 1
    exec_git(argv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
