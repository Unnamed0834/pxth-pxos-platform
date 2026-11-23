

{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.paxos.releaseVerify;


  releaseVerify = pkgs.writeShellApplication {
    name = "paxos-release-verify";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils
    ];
    text = builtins.readFile ../../scripts/release-verify.sh;
  };

  releaseCheck =
    if cfg.enable then
      ''
        sig=''${4:-}
        if [ "$#" -ne 4 ] || [ -z "$sig" ]; then
          echo "ops: release signature required" >&2
          exit 1
        fi
        case "$sig" in
          *[!A-Za-z0-9+/=]*)
            echo "ops: bad release signature" >&2
            exit 1
            ;;
        esac
        if [ "''${#sig}" -lt 40 ] || [ "''${#sig}" -gt 8192 ]; then
          echo "ops: bad release signature" >&2
          exit 1
        fi
        if [[ ! $rev =~ ^[0-9a-f]{40}$ ]]; then
          echo "ops: bad revision" >&2
          exit 1
        fi
        if ! ${releaseVerify}/bin/paxos-release-verify verify \
          --public-key ${lib.escapeShellArg cfg.publicKey} \
          --path "$path" \
          --rev "$rev" \
          --signature "$sig"
        then
          echo "ops: release signature rejected" >&2
          logger -t paxos-alert -p user.notice -- \
            "result=signature-rejected host=$(hostname -s) rev=$rev path=$path" || true
          exit 1
        fi
      ''
    else
      "";
in
{
  imports = [ ./release-verify.nix ];
  users.groups.ops.gid = 1001;

  users.users.ops = {
    isNormalUser = true;
    uid = 1001;
    group = "ops";
    extraGroups = [ "wheel" ];
    home = "/var/lib/ops";
    createHome = true;
    hashedPassword = "!";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      ''from="192.0.2.10" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEOPSKEYPLACEHOLDER ops@example.com''
      ''from="198.51.100.21,198.51.100.22",restrict,command="/run/current-system/sw/bin/paxos-ci-switch" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLECIKEYPLACEHOLDER ci-deploy''
    ];
  };

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "paxos-ops-switch";
      runtimeInputs = [
        pkgs.nixos-rebuild
        pkgs.systemd
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.util-linux
      ];
      text = ''
        action=''${1:-}
        case "$action" in
          switch)
            path=''${2:-}
            rev=''${3:-unknown}
            if [ "$#" -ne 2 ] && [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; then
              echo "ops: switch takes the store path and an optional revision" >&2
              exit 1
            fi
            case "$path" in
              /nix/store/*) ;;
              *)
                echo "ops: switch needs a /nix/store path" >&2
                exit 1
                ;;
            esac
            case "$path" in
              *..*|*[[:space:]]*)
                echo "ops: bad store path" >&2
                exit 1
                ;;
            esac
            case "$rev" in
              *[[:space:]]*|*"'"*)
                echo "ops: bad revision" >&2
                exit 1
                ;;
            esac
            if [ ! -d "$path" ]; then
              echo "ops: store path is not present" >&2
              exit 1
            fi
            ${releaseCheck}
            if ! nixos-rebuild switch --store-path "$path" --no-reexec; then
              logger -t paxos-alert -p user.notice -- \
                "result=switch-failed host=$(hostname -s) rev=$rev path=$path" || true
              exit 1
            fi
            logger -t paxos-alert -p user.notice -- \
              "result=activated host=$(hostname -s) rev=$rev path=$path" || true
            ;;
          rollback)
            if [ "$#" -ne 1 ]; then
              echo "ops: rollback takes no arguments" >&2
              exit 1
            fi
            exec nixos-rebuild switch --rollback --no-reexec
            ;;
          restore)
            if [ "$#" -ne 1 ]; then
              echo "ops: restore takes no arguments" >&2
              exit 1
            fi
            manifest=/persist/var/lib/stack-moves
            if [ -f "$manifest" ]; then
              while IFS=$(printf '\t') read -r old new; do
                case "$old" in
                  /persist/var/lib/containers/home/.local/share/containers/storage/volumes/*/_data) ;;
                  "") continue ;;
                  *)
                    echo "ops: refusing to restore $old" >&2
                    exit 1
                    ;;
                esac
                case "$new" in
                  /persist/var/lib/stack/*/_data) ;;
                  *)
                    echo "ops: refusing to restore $new" >&2
                    exit 1
                    ;;
                esac
                name=''${new#/persist/var/lib/stack/}
                name=''${name%%/*}
                systemctl stop "$name.service" "$name-stack.service" || true
                if [ -d "$new" ] && [ ! -e "$old" ]; then
                  mkdir -p "$(dirname "$old")"
                  mv "$new" "$old"
                fi
              done < "$manifest"
              rm -f "$manifest"
            fi
            shopt -s nullglob
            for d in \
              /persist/var/lib/stack/*/.local/share/containers/storage/overlay \
              /persist/var/lib/stack/*/.local/share/containers/storage/overlay-layers \
              /persist/var/lib/stack/*/.local/share/containers/storage/overlay-images \
              /persist/var/lib/stack/*/.local/share/containers/storage/overlay-containers
            do
              rm -rf "$d"
            done
            ;;
          commit)
            if [ "$#" -ne 1 ]; then
              echo "ops: commit takes no arguments" >&2
              exit 1
            fi
            manifest=/persist/var/lib/stack-moves
            if [ ! -f "$manifest" ]; then
              exit 0
            fi
            while IFS=$(printf '\t') read -r old new; do
              case "$new" in
                /persist/var/lib/stack/*/_data) ;;
                "") continue ;;
                *)
                  echo "ops: refusing to commit $new" >&2
                  exit 1
                  ;;
              esac
              name=''${new#/persist/var/lib/stack/}
              name=''${name%%/*}
              for unit in "$name.service" "$name-stack.service"; do
                if systemctl cat "$unit" >/dev/null 2>&1; then
                  state=$(systemctl is-active "$unit" || true)
                  if [ "$state" != active ]; then
                    echo "ops: $unit is $state, keeping the rename record" >&2
                    exit 1
                  fi
                fi
              done
            done < "$manifest"
            rm -f "$manifest"
            ;;
          *)
            echo "ops: switch <store-path> [rev] [signature] | rollback | restore | commit" >&2
            exit 1
            ;;
        esac
      '';
    })
    (pkgs.writeShellApplication {
      name = "paxos-ci-switch";


      runtimeInputs = [
        pkgs.nix
        pkgs.coreutils
      ];


      text = ''
        orig=''${SSH_ORIGINAL_COMMAND:-}
        orig=''${orig%$'\n'}
        rest=
        case "$orig" in
          ""|*$'\n'*)
            echo "ci: rejected command" >&2
            exit 1
            ;;
          "nix-store --serve --write")
            exec nix-store --serve --write
            ;;
          "readlink -f /run/current-system")
            exec readlink -f /run/current-system
            ;;
          "paxos-ops-switch rollback")
            exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/paxos-ops-switch rollback
            ;;
          "paxos-ops-switch restore")
            exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/paxos-ops-switch restore
            ;;
          "paxos-ops-switch commit")
            exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/paxos-ops-switch commit
            ;;
          "paxos-ops-switch switch "*)
            rest=''${orig#"paxos-ops-switch switch "}
            ;;
          *)
            echo "ci: rejected command" >&2
            exit 1
            ;;
        esac
        sig=
        case "$rest" in
          *$'\t'*|*$'\n'*|*$'\r'*|*[[:space:]][[:space:]]*)
            echo "ci: rejected command" >&2
            exit 1
            ;;
          *" "*)
            store=''${rest%% *}
            tail=''${rest#* }
            case "$tail" in
              *" "*)
                rev=''${tail%% *}
                sig=''${tail#* }
                ;;
              *)
                rev=$tail
                ;;
            esac
            ;;
          *)
            store=$rest
            rev=
            ;;
        esac
        case "$store" in
          *..*|*[[:space:]]*)
            echo "ci: bad store path" >&2
            exit 1
            ;;
        esac
        if [[ ! $store =~ ^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9._+-]+$ ]]; then
          echo "ci: bad store path" >&2
          exit 1
        fi
        if [ -n "$rev" ]; then
          if [[ ! $rev =~ ^[0-9a-f]{40}$ ]]; then
            echo "ci: bad revision" >&2
            exit 1
          fi
        fi
        if [ -n "$sig" ]; then
          case "$sig" in
            *" "*|*[!A-Za-z0-9+/=]*)
              echo "ci: bad release signature" >&2
              exit 1
              ;;
          esac
          if [ -z "$rev" ] || [ "''${#sig}" -lt 40 ] || [ "''${#sig}" -gt 8192 ]; then
            echo "ci: bad release signature" >&2
            exit 1
          fi
          exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/paxos-ops-switch switch "$store" "$rev" "$sig"
        fi
        if [ -n "$rev" ]; then
          exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/paxos-ops-switch switch "$store" "$rev"
        fi
        exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/paxos-ops-switch switch "$store"
      '';
    })
  ];

  system.activationScripts.paxosOpsKeys = lib.stringAfter [ "etc" ] ''
    for pair in \
      /run/current-system/etc/ssh/authorized_keys.d/ops:/etc/ssh/authorized_keys.d/ops \
      /run/current-system/etc/sudoers:/etc/sudoers
    do
      src=''${pair%%:*}
      dest=''${pair#*:}
      if [ -s "$src" ] && [ ! -s "$dest" ]; then
        cp -L "$src" "$dest"
        case "$dest" in
          */sudoers) chmod 440 "$dest" ;;
          *) chmod 644 "$dest" ;;
        esac
      fi
    done
  '';

  security.sudo.extraRules = [
    {
      users = [ "ops" ];
      commands = [
        {
          command = "ALL";
          options = [ "PASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/paxos-ops-switch";
          options = [
            "NOPASSWD"
            "SETENV"
          ];
        }
      ];
    }
  ];
}
