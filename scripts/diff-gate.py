#!/usr/bin/env python3

import argparse
import re
import subprocess
import sys
from collections import Counter

ALLOW = "#[" + "allow"
IGNORE = "#[" + "ignore"
SKIP = "pytest." + "skip"
XFAIL = "pytest." + "xfail"
MARK_SKIP = "pytest." + "mark." + "skip"
CHEATS = (ALLOW, IGNORE, SKIP, XFAIL, MARK_SKIP)

ATTR = re.compile(r"^[ \t]*#\[(?:[A-Za-z_]\w*::)*test(?:\([^)]*\))?\][ \t]*$")
FN_TEST = re.compile(
    r"^[ \t]*(?:async[ \t]+)?def[ \t]+(test_[A-Za-z0-9_]+)\b"
    r"|^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:async[ \t]+)?fn[ \t]+(test_[A-Za-z0-9_]+)\b"
)
FN_ANY = re.compile(
    r"^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:async[ \t]+)?fn[ \t]+([A-Za-z_][A-Za-z0-9_]*)\b"
    r"|^[ \t]*(?:async[ \t]+)?def[ \t]+(test_[A-Za-z0-9_]+)\b"
)
LINT_TABLE = re.compile(r"^\s*\[(?:workspace\.)?lints(?:\.|\])")
REFEREE_NAMES = {
    "scripts/diff-gate.py",
    "scripts/git-push-guard.py",
    "clippy.toml",
    ".clippy.toml",
    "rustfmt.toml",
}
HOLLOW = re.compile(r"^(?:pass|\.\.\.|todo!\(\)|unimplemented!\(\)|return;?)$")
TRIVIAL_ASSERT = re.compile(
    r"^assert(?:!)?\s*(?:\(\s*)?(?:True|true|False|false)(?:\s*\))?\s*;?$"
    r"|^assert_eq!\(\s*(?:true|false|True|False)\s*,\s*(?:true|false|True|False)\s*\)\s*;?$"
)
REAL_ASSERT = re.compile(r"(?:^|[^\w])assert(?:!|\s|_|$)")


def header_paths(line):
    if not line.startswith("diff --git "):
        return []
    marker = " b/"
    idx = line.rfind(marker)
    if idx == -1:
        return []
    new = line[idx + len(marker):]
    left = line[len("diff --git "):idx]
    old = left[2:] if left.startswith("a/") else left
    return [path for path in (old, new) if path and path != "/dev/null"]


def split_files(diff):
    current = []
    lines = []
    found = []
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            if current:
                found.append((current, lines))
            current = header_paths(line)
            lines = []
            continue
        if not current:
            continue
        if line.startswith("---") or line.startswith("+++"):
            continue
        if line.startswith("@@") or line[:1] in "+- \\":
            lines.append(line)
    if current:
        found.append((current, lines))
    return found


def referee(path):
    name = path.rsplit("/", 1)[-1]
    if path in REFEREE_NAMES or name in {"clippy.toml", ".clippy.toml", "rustfmt.toml"}:
        return True
    return False


def fn_name(body):
    matched = FN_ANY.match(body)
    if matched is None:
        return None
    return matched.group(1) or matched.group(2)


def test_def_name(body):
    matched = FN_TEST.match(body)
    if matched is None:
        return None
    return matched.group(1) or matched.group(2)


def removed_tests(lines):
    removed = Counter()
    added = Counter()
    for line in lines:
        prefix = line[:1]
        if prefix not in "+-":
            continue
        name = test_def_name(line[1:])
        if name is None:
            continue
        if prefix == "-":
            removed[name] += 1
        else:
            added[name] += 1
    for index, line in enumerate(lines):
        if not line.startswith("-") or ATTR.match(line[1:]) is None:
            continue
        name = None
        kept = False
        for nxt in lines[index + 1:index + 6]:
            if nxt.startswith("+") and ATTR.match(nxt[1:]):
                kept = True
            body = nxt[1:] if nxt[:1] in "+- " else nxt
            found = fn_name(body)
            if found is not None:
                name = found
                break
        if name is not None and not kept:
            removed[name] += 1
            if any(item.startswith("+") and test_def_name(item[1:]) == name for item in lines):
                added[name] += 1
    gone = []
    for name in sorted(removed):
        if removed[name] > added[name]:
            gone.append(name)
    return gone


def added_cheats(lines):
    found = []
    for line in lines:
        if not line.startswith("+") or line.startswith("+++"):
            continue
        body = line[1:]
        for marker in CHEATS:
            if marker in body:
                found.append("added " + marker)
                break
    return found


def comment_or_blank(body):
    text = body.strip()
    if not text:
        return True
    return text.startswith(("//", "#", "/*", "*", "*/"))


def lock_file(path):
    return path == "flake.lock" or path.endswith("/flake.lock")


def lock_only_silence(files, cheats):
    if not cheats:
        return False
    for paths, lines in files:
        if paths and all(lock_file(path) for path in paths):
            continue
        for line in lines:
            if not line.startswith("+"):
                continue
            body = line[1:]
            if comment_or_blank(body):
                continue
            if any(marker in body for marker in CHEATS):
                continue
            return False
    return True


def indent_width(line):
    return len(line) - len(line.lstrip(" \t"))


def marked_side(lines, side):
    found = []
    for line in lines:
        if line.startswith("@@"):
            found.append((None, False))
            continue
        if line.startswith("\\"):
            continue
        prefix = line[:1]
        if prefix == " ":
            found.append((line[1:], False))
        elif prefix == side:
            found.append((line[1:], True))
    return found


def changed_functions(marked):
    found = []
    index = 0
    total = len(marked)
    while index < total:
        text, changed = marked[index]
        if text is None:
            index += 1
            continue
        name = test_def_name(text)
        if name is None:
            index += 1
            continue
        def_indent = indent_width(text)
        body = []
        touched = changed
        index += 1
        complete = False
        while index < total:
            nxt, nxt_changed = marked[index]
            if nxt is None:
                break
            if nxt.strip() == "":
                body.append(nxt)
                touched = touched or nxt_changed
                index += 1
                continue
            if indent_width(nxt) <= def_indent:
                complete = True
                break
            body.append(nxt)
            touched = touched or nxt_changed
            index += 1
        if touched and complete:
            found.append((name, body))
    return found


def meaningful(body):
    rows = []
    for line in body:
        text = line.strip()
        if not text or text.startswith(("//", "#", "/*", "*", "*/")):
            continue
        rows.append(text)
    return rows


def hollow_line(text):
    return HOLLOW.fullmatch(text) is not None or TRIVIAL_ASSERT.fullmatch(text) is not None


def real_asserts(body):
    count = 0
    for text in meaningful(body):
        if hollow_line(text):
            continue
        if REAL_ASSERT.search(text):
            count += 1
    return count


def hollow_tests(lines):
    old = {name: body for name, body in changed_functions(marked_side(lines, "-"))}
    found = []
    seen = set()
    for name, body in changed_functions(marked_side(lines, "+")):
        rows = meaningful(body)
        item = None
        if not rows or all(hollow_line(row) for row in rows):
            item = "hollow test " + name
        else:
            previous = old.get(name)
            if previous is not None and real_asserts(previous) > 0 and real_asserts(body) == 0:
                item = "gutted test " + name
        if item is not None and item not in seen:
            seen.add(item)
            found.append(item)
    return found


def violations(diff, lock=False, bootstrap=False):
    files = split_files(diff or "")
    found = []
    seen = set()
    for paths, lines in files:
        for name in removed_tests(lines):
            item = "removed test " + name
            if item not in seen:
                seen.add(item)
                found.append(item)
        for item in hollow_tests(lines):
            if item not in seen:
                seen.add(item)
                found.append(item)
        if not bootstrap:
            for path in paths:
                if referee(path):
                    item = "edits referee " + path
                    if item not in seen:
                        seen.add(item)
                        found.append(item)
                if path.rsplit("/", 1)[-1] == "Cargo.toml":
                    for line in lines:
                        if line.startswith("+") and LINT_TABLE.match(line[1:]):
                            item = "edits lint table " + path
                            if item not in seen:
                                seen.add(item)
                                found.append(item)
                            break
        for item in added_cheats(lines):
            if item not in seen:
                seen.add(item)
                found.append(item)
    cheats = [item for item in found if item.startswith("added ")]
    if lock and lock_only_silence(files, cheats):
        found.append("lock repair's only code change silences a check")
    return found


def load_diff(repo, base, head):
    proc = subprocess.run(
        ["git", "-C", repo, "diff", "--no-ext-diff", "-U3", base + "..." + head],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo")
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--lock", action="store_true")
    parser.add_argument("--bootstrap", action="store_true")
    args = parser.parse_args(argv)
    if not args.repo or not args.base or not args.head:
        print("diff-gate: missing repo, base, or head", file=sys.stderr)
        return 2
    diff = load_diff(args.repo, args.base, args.head)
    if diff is None:
        print("diff-gate: could not read the diff", file=sys.stderr)
        return 2
    found = violations(diff, lock=args.lock, bootstrap=args.bootstrap)
    for item in found:
        print(item)
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
