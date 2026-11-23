#!/bin/bash
set -euo pipefail

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

usage() {
  cat <<'EOF'
Usage: bootstrap.sh <host> --installer-ip <ip> [--age-key PATH] [--flake PATH] [--ssh-user USER]

  Eval-check the host, nixos-anywhere it onto the metal target (remote build),
  record the artifact manifest.
EOF
}

host="${1:-}"
shift || true
if [ -z "$host" ]; then usage; exit 1; fi

installer_ip=""
age_key="${PAXOS_AGE_KEY:-}"
flake=""
ssh_user="${PAXOS_SSH_USER:-root}"
while [ $# -gt 0 ]; do
  case "$1" in
    --installer-ip) installer_ip="$2"; shift ;;
    --age-key) age_key="$2"; shift ;;
    --flake) flake="$2"; shift ;;
    --ssh-user) ssh_user="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
  shift
done
if [ -z "$installer_ip" ]; then echo "--installer-ip required" >&2; exit 1; fi
if [ -z "$flake" ]; then
  if [ -e /pxth-pxos-platform/flake.nix ]; then flake=/pxth-pxos-platform; else flake="$HOME/workspace/pxth-pxos-platform"; fi
fi

if [ -z "$age_key" ]; then
  repo_root=$(git -C "$flake" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$flake")
  age_key="/run/secrets/age-key"
fi
if [ ! -f "$age_key" ]; then
  echo "age identity not found: $age_key" >&2
  echo "stage the fleet key out-of-band (scp from node-01 sealed copy), never commit it" >&2
  exit 1
fi

if [ ! -d "$flake" ]; then echo "flake not found: $flake" >&2; exit 1; fi

echo "==> eval ${host}"
nix eval --no-write-lock-file "${flake}#nixosConfigurations.${host}.config.networking.hostName"

rev=$(git -C "$flake" rev-parse --short HEAD 2>/dev/null || echo "dirty")

echo "==> stage age key on tmpfs (shredded after)"
EXTRA=$(mktemp -d)
mkdir -p "$EXTRA/persist/secrets"
install -m 600 "$age_key" "$EXTRA/persist/secrets/key.txt"
chmod 700 "$EXTRA/persist/secrets"
cleanup() { rm -rf "$EXTRA"; }
trap cleanup EXIT

echo "==> probe installer ssh ${installer_ip}:22"
for i in $(seq 1 30); do
  if timeout 2 bash -c "echo >/dev/tcp/${installer_ip}/22" 2>/dev/null; then break; fi
  sleep 4
  if [ "$i" = 30 ]; then echo "installer ssh unreachable" >&2; exit 1; fi
done

echo "==> allow unsigned paths on installer (ephemeral ISO only; installed system enforces sigs)"
export SSHPASS="${SSHPASS:-nixos}"
sshpass -e ssh -o UserKnownHostsFile="/tmp/${host}-installer-kh" -o StrictHostKeyChecking=no \
  "${ssh_user}@${installer_ip}" \
  "orig=\$(readlink /etc/nix/nix.conf || true); rm -f /etc/nix/nix.conf; if [ -n \"\$orig\" ] && [ -f \"\$orig\" ]; then cat \"\$orig\" > /etc/nix/nix.conf 2>/dev/null || { printf 'require-sigs = false\n' > /tmp/nix.conf; mount --bind /tmp/nix.conf /etc/nix/nix.conf; exit 0; }; fi; printf 'require-sigs = false\n' >> /etc/nix/nix.conf"

echo "==> nixos-anywhere ${host} -> ${ssh_user}@${installer_ip} (disko formats target, build on remote)"
export SSHPASS="${SSHPASS:-nixos}"
nix run github:nix-community/nixos-anywhere -- \
  --flake "${flake}#${host}" \
  --target-host "${ssh_user}@${installer_ip}" \
  --env-password \
  --build-on remote \
  --extra-files "$EXTRA" \
  --print-build-logs \
  --ssh-option "UserKnownHostsFile=/tmp/${host}-installer-kh" \
  --ssh-option "StrictHostKeyChecking=no"

mkdir -p "${flake}/bootstrap/artifacts"
manifest="${flake}/bootstrap/artifacts/${host}-enclosure.json"
printf '{"host":"%s","build_on":"remote","rev":"%s","date":"%s"}\n' \
  "$host" "$rev" "$(date -u +%FT%TZ)" > "$manifest"
echo "manifest: $manifest"

echo "ok ${host} bootstrapped; verify: ssh operator@<final-static-ip> (host config address, not installer DHCP)"
