#!/usr/bin/env bash
set -euo pipefail

namespace=paxos-release
principal=paxos-release

usage() {
  echo "usage: release-verify.sh sign --key FILE --path STORE --rev REV" >&2
  echo "       release-verify.sh verify --public-key TEXT --path STORE --rev REV --signature TOKEN" >&2
  exit 2
}

die() {
  echo "release-verify: $*" >&2
  exit 1
}

require_path() {
  local path=$1
  if [[ ! $path =~ ^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9._+-]+$ ]]; then
    die "bad store path"
  fi
}

require_rev() {
  local rev=$1
  if [[ ! $rev =~ ^[0-9a-f]{40}$ ]]; then
    die "bad revision"
  fi
}

write_payload() {
  local path=$1 rev=$2 dest=$3
  require_path "$path"
  require_rev "$rev"
  printf '%s\n%s\n%s\n' "paxos-release v1" "$path" "$rev" > "$dest"
}

allowed_line() {
  local line=$1 keytype rest keyblob
  line=${line%$'\r'}
  case "$line" in
    *$'\n'*) die "public key must be one line" ;;
  esac
  keytype=${line%% *}
  rest=${line#* }
  keyblob=${rest%% *}
  case "$keytype" in
    ssh-ed25519 | ssh-rsa | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521 | sk-ssh-ed25519@openssh.com | sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) die "unsupported public key" ;;
  esac
  case "$keyblob" in
    AAAA[A-Za-z0-9+/=]*) ;;
    *) die "bad public key" ;;
  esac
  printf '%s namespaces="%s" %s %s\n' "$principal" "$namespace" "$keytype" "$keyblob"
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

key=""
public_key=""
path=""
rev=""
signature=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key)
      [ $# -ge 2 ] || usage
      key=$2
      shift 2
      ;;
    --public-key)
      [ $# -ge 2 ] || usage
      public_key=$2
      shift 2
      ;;
    --path)
      [ $# -ge 2 ] || usage
      path=$2
      shift 2
      ;;
    --rev)
      [ $# -ge 2 ] || usage
      rev=$2
      shift 2
      ;;
    --signature)
      [ $# -ge 2 ] || usage
      signature=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$path" ] && [ -n "$rev" ] || usage

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
write_payload "$path" "$rev" "$work/msg"

case "$cmd" in
  sign)
    [ -n "$key" ] || usage
    [ -f "$key" ] || die "key is not a file"
    ssh-keygen -q -Y sign -f "$key" -n "$namespace" < "$work/msg" > "$work/sig"
    base64 -w0 "$work/sig"
    printf '\n'
    ;;
  verify)
    [ -n "$public_key" ] && [ -n "$signature" ] || usage
    case "$signature" in
      *[!A-Za-z0-9+/=]*) die "bad signature token" ;;
    esac
    if [ "${#signature}" -lt 40 ] || [ "${#signature}" -gt 8192 ]; then
      die "bad signature token"
    fi
    allowed_line "$public_key" > "$work/allowed"
    if ! printf '%s' "$signature" | base64 -d > "$work/sig"; then
      die "bad signature token"
    fi
    ssh-keygen -Y verify \
      -f "$work/allowed" \
      -I "$principal" \
      -n "$namespace" \
      -s "$work/sig" \
      < "$work/msg" \
      > /dev/null
    ;;
  *)
    usage
    ;;
esac
