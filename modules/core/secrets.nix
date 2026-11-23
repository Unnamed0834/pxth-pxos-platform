{
  lib,
  config,
  pkgs,
  ...
}:

let
  actText =
    name:
    let
      s = config.system.activationScripts.${name} or "";
    in
    if builtins.isString s then s else (s.text or "");
  plant = pkgs.writeShellScriptBin "paxos-plant-age-key" ''
    set -euo pipefail
    dest=${lib.escapeShellArg config.paxos.secrets.keyFile}
    if [ -L "$dest" ] || [ -s "$dest" ]; then
      echo "paxos-plant-age-key: identity already present" >&2
      exit 1
    fi
    install -d -m 0700 -o root -g root "$(dirname "$dest")"
    umask 077
    tmp=$(mktemp "$dest.XXXXXX")
    cat > "$tmp"
    if [ ! -s "$tmp" ]; then
      rm -f "$tmp"
      echo "paxos-plant-age-key: empty identity" >&2
      exit 1
    fi
    mv -f "$tmp" "$dest"
    chmod 600 "$dest"
  '';
in
{
  options.paxos.secrets = {
    keyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "${config.paxos.persist.secretsDir}/key.txt";
      description = "Age identity path (also referenced by age.identityPaths in modules/platform/base.nix).";
    };

    app = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            file = lib.mkOption {
              type = lib.types.path;
              description = "Age-encrypted secret file.";
            };
            owner = lib.mkOption {
              type = lib.types.str;
              description = "Owner of the decrypted secret.";
            };
            group = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Group of the decrypted secret. Null leaves agenix's default.";
            };
            mode = lib.mkOption {
              type = lib.types.str;
              default = "0400";
            };
            path = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Install path. Null leaves agenix's /run/agenix/<name>.";
            };
          };
        }
      );
      default = { };
      description = "Host-owned app secrets. Expands to age.secrets with the same names.";
    };
  };

  config = lib.mkMerge [
    {
      age.secrets = lib.mapAttrs (
        _: s:
        {
          inherit (s) file owner mode;
        }
        // lib.optionalAttrs (s.group != null) { inherit (s) group; }
        // lib.optionalAttrs (s.path != null) { inherit (s) path; }
      ) config.paxos.secrets.app;
    }
    (lib.mkIf (config.age.secrets != { }) {
      environment.systemPackages = [ plant ];
      security.sudo.extraRules = [
        {
          users = [ "operator" ];
          commands = [
            {
              command = "${plant}/bin/paxos-plant-age-key";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
      systemd.services.agenix-decrypt = {
        description = "Decrypt agenix secrets once a persist identity exists";
        after = [ "local-fs.target" ];
        path = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.util-linux
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "infinity";
        };
        script = ''
          set -euo pipefail
          identities=( ${lib.concatMapStringsSep " " lib.escapeShellArg config.age.identityPaths} )
          echo "agenix-decrypt: waiting for age identity"
          while true; do
            for k in "''${identities[@]}"; do
              if [ -s "$k" ]; then
                echo "agenix-decrypt: using $k"
                break 2
              fi
            done
            sleep 1
          done
          ${actText "agenixNewGeneration"}
          ${actText "agenixInstall"}
          ${actText "users"}
          ${actText "paxosPinIds"}
          ${actText "agenixChown"}
        '';
      };
    })
  ];
}
