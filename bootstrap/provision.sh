#!/bin/bash
set -euo pipefail

export NIX_CONFIG="experimental-features = nix-command flakes"

nix --version
for bin in ssh git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing base tool: $bin" >&2; exit 1; }
done

for pkg in sshpass git; do
  bin="$pkg"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "installing ${pkg} to user profile…"
    nix --extra-experimental-features 'nix-command flakes' \
      profile install "nixpkgs#${pkg}"
  fi
done
hash -r

echo "checking nixos-anywhere resolves…"
nix flake metadata github:nix-community/nixos-anywhere --no-write-lock-file >/dev/null
echo "bootstrap guest provisioned: nix (native) + nixos-anywhere (run-mode) ready"
