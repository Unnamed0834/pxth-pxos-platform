#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

unfixed_file=${CLOSURE_SCAN_UNFIXED:-$root/scripts/closure-scan-unfixed.txt}
template=$root/scripts/closure-scan.tmpl
image_scan=$root/scripts/image-scan.sh

usage() {
  cat <<'EOF'
usage: scripts/closure-scan.sh [HOST]
       scripts/closure-scan.sh --check-clock
       scripts/closure-scan.sh --apply-matches PACKAGE-ID

Scan one NixOS toplevel with grype. The default host is node-02.
One host only. If the toplevel is not already in the store, exit.
This does not start a realisation.

  nix develop .#scan -c scripts/closure-scan.sh dev

dev is where closures are built; the Forgejo nix job does not keep them.

Unfixed findings are lines in scripts/closure-scan-unfixed.txt.
That file is separate from scripts/image-scan-unfixed.txt because a
closure package id is not an image ref. The 30 UTC day clock and the
fixed / unfixed rules are the image-scan rules.

--check-clock and --apply-matches do not resolve a host.
EOF
}

rewrite() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      image-scan:*)
        printf 'closure-scan:%s\n' "${line#image-scan:}"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done
}

delegate() {
  local tmp_out tmp_err rc
  tmp_out=$(mktemp)
  tmp_err=$(mktemp)
  rc=0
  IMAGE_SCAN_GATE=high IMAGE_SCAN_UNFIXED=$unfixed_file "$image_scan" "$@" >"$tmp_out" 2>"$tmp_err" || rc=$?
  rewrite <"$tmp_out"
  rewrite <"$tmp_err" >&2
  rm -f "$tmp_out" "$tmp_err"
  return "$rc"
}

finish_delegate() {
  local rc
  set +e
  delegate "$@"
  rc=$?
  set -e
  exit "$rc"
}

apply_closure_matches() {
  local line sev state cve pkg extra current="" buf failed=0
  buf=$(mktemp)
  current=""
  flush_group() {
    if [ -z "$current" ]; then
      : >"$buf"
      return 0
    fi
    if ! delegate --apply-matches "$current" <"$buf"; then
      failed=$((failed + 1))
    fi
    : >"$buf"
  }
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    sev=""
    state=""
    cve=""
    pkg=""
    extra=""
    read -r sev state cve pkg extra <<<"$line"
    if [ -n "$sev" ] && [ -z "${pkg:-}" ] && [ -z "${extra:-}" ] \
      && [[ $state == CVE-* || $state == GHSA-* ]] \
      && [[ $cve == */*@* ]]; then
      pkg=$cve
      cve=$state
      state=unknown
    fi
    if [ -z "$sev" ] || [ -z "$state" ] || [ -z "$cve" ] || [ -z "$pkg" ] || [ -n "$extra" ]; then
      echo "closure-scan: bad grype match: $line" >&2
      failed=$((failed + 1))
      continue
    fi
    if [ "$pkg" != "$current" ]; then
      flush_group
      current=$pkg
    fi
    printf '%s %s %s\n' "$sev" "$state" "$cve" >>"$buf"
  done
  flush_group
  rm -f "$buf"
  [ "$failed" -eq 0 ]
}

resolve_toplevel() {
  local host=$1
  if [ -n "${CLOSURE_SCAN_STORE_PATH:-}" ]; then
    printf '%s\n' "$CLOSURE_SCAN_STORE_PATH"
    return 0
  fi
  echo "closure-scan: resolving $host toplevel without realising it" >&2
  nix eval --raw \
    --option allow-import-from-derivation false \
    ".#nixosConfigurations.${host}.config.system.build.toplevel.outPath"
}

case ${1:-} in
  --help | -h)
    usage
    exit 0
    ;;
  --check-clock)
    finish_delegate --check-clock
    ;;
  --apply-matches)
    finish_delegate "$@"
    ;;
esac

if [ "$#" -gt 1 ]; then
  echo "closure-scan: one host only" >&2
  exit 2
fi

host=${1:-node-02}
case "$host" in
  "" | *[!A-Za-z0-9_-]*)
    echo "closure-scan: bad host name: $host" >&2
    exit 2
    ;;
esac

if ! out=$(resolve_toplevel "$host"); then
  echo "closure-scan: could not resolve $host toplevel without realising it" >&2
  exit 1
fi
if [ ! -e "$out" ]; then
  echo "closure-scan: $host toplevel is not in the store ($out)." >&2
  echo "closure-scan: refusing to build. Realise the closure on node-02, then re-run." >&2
  echo "closure-scan:   nix develop .#scan -c scripts/closure-scan.sh $host" >&2
  exit 1
fi

if ! command -v grype >/dev/null 2>&1; then
  echo "closure-scan: grype is not on PATH (nix develop .#scan)" >&2
  exit 1
fi

closure_root=$(mktemp -d)
closure_list=$(mktemp)
cleanup() {
  [ -n "${closure_root:-}" ] && rm -rf "$closure_root"
  [ -n "${closure_list:-}" ] && rm -f "$closure_list"
}
trap cleanup EXIT

if ! nix-store -qR "$out" >"$closure_list"; then
  echo "closure-scan: could not query the runtime closure of $out" >&2
  exit 1
fi

mkdir -p "$closure_root/nix/store"
n=0
while IFS= read -r store_path || [ -n "$store_path" ]; do
  [ -n "$store_path" ] || continue
  case "$store_path" in
    *.drv) continue ;;
  esac
  base=${store_path##*/}
  case "$base" in
    "" | .* | */*) continue ;;
  esac
  mkdir -p "$closure_root/nix/store/$base"
  n=$((n + 1))
done <"$closure_list"

if [ "$n" -eq 0 ]; then
  echo "closure-scan: runtime closure of $out is empty" >&2
  exit 1
fi

echo "closure-scan: $host $out ($n store paths)"
if ! matches=$(grype "dir:${closure_root}" -o template -t "$template"); then
  echo "closure-scan: grype failed for $host" >&2
  exit 1
fi

sorted=$(printf '%s\n' "$matches" | sort -k4,4)
failed=0
if ! apply_closure_matches <<<"$sorted"; then
  failed=1
fi

set +e
delegate --check-clock
clock_rc=$?
set -e

if [ "$failed" -ne 0 ]; then
  echo "closure-scan: FAIL: closure package has an unlisted or fixed high or critical CVE" >&2
  exit 1
fi
if [ "$clock_rc" -ne 0 ]; then
  exit 1
fi
echo "closure-scan: OK"
