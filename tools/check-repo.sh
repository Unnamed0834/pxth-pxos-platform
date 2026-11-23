#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
count=0

check() {
  local name="$1" pattern="$2"
  local out
  out="$(grep -rInE \
      --exclude-dir=.git \
      --exclude='check-repo.sh' \
      --exclude='.gitleaks.toml' \
      --exclude='README.md' \
      "$pattern" . 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    printf 'FAIL  %-30s\n' "$name"
    printf '%s\n' "$out" | head -20 | sed 's/^/        /'
    fail=1
    count=$(( count + 1 ))
  else
    printf 'PASS  %s\n' "$name"
  fi
}

echo "== repository checks =="

check "key material" \
  'BEGIN (RSA |EC |DSA |OPENSSH |OPENPGP )?PRIVATE KEY|AGE-SECRET-KEY-1[1-9A-Za-z]{20,}'
check "internal domains" \
  '\.(int|internal)\.[a-z]+'
check "private addresses" \
  '(^|[^0-9])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
check "hosting tokens" \
  '(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{24,})'

echo
echo "== structure =="

if find . -mindepth 2 -name .git -type d -print -quit | grep -q .; then
  echo "FAIL  nested git repositories"
  fail=1
  count=$(( count + 1 ))
else
  echo "PASS  no nested git repositories"
fi

secret_files=$(find . -type f \( -name '*.age' -o -name 'identity.pub' -o -name '.sops.yaml' \) | wc -l | tr -d ' ')
if [[ "$secret_files" != "0" ]]; then
  echo "FAIL  secret files present: $secret_files"
  fail=1
  count=$(( count + 1 ))
else
  echo "PASS  no secret files"
fi

for f in LICENSE; do
  if [[ -f "$f" ]]; then
    echo "PASS  $f present"
  else
    echo "FAIL  $f missing"
    fail=1
    count=$(( count + 1 ))
  fi
done

echo
if [[ "$fail" -ne 0 ]]; then
  echo "RESULT: FAILED — $count check(s)"
  exit 1
fi
echo "RESULT: PASS"
