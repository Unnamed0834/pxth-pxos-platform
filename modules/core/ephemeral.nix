{
  config,
  lib,
  pkgs,
  ...
}:


let
  cfg = config.paxos.ephemeral;
  specId = config.paxos.spec.id or null;
  placed = specId != null;

  persistEntry = lib.types.submodule (
    { config, ... }: {
      options = {
        path = lib.mkOption {
          type = lib.types.str;
          description = "Live path on the tmpfs root.";
        };
        store = lib.mkOption {
          type = lib.types.str;
          default = lib.removePrefix "/" config.path;
          defaultText = lib.literalExpression "path without leading /";
          description = "Path under persistPath (or absolute).";
        };
        kind = lib.mkOption {
          type = lib.types.enum [
            "directory"
            "file"
          ];
          default = "directory";
        };
        mode = lib.mkOption {
          type = lib.types.str;
          default = "0755";
        };
        user = lib.mkOption {
          type = lib.types.str;
          default = "root";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "root";
        };
        neededForBoot = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        parents = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                store = lib.mkOption { type = lib.types.str; };
                mode = lib.mkOption {
                  type = lib.types.str;
                  default = "0755";
                };
                user = lib.mkOption {
                  type = lib.types.str;
                  default = "root";
                };
                group = lib.mkOption {
                  type = lib.types.str;
                  default = "root";
                };
              };
            }
          );
          default = [ ];
          description = "Backing directories to create before the entry.";
        };
        children = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                name = lib.mkOption { type = lib.types.str; };
                mode = lib.mkOption {
                  type = lib.types.str;
                  default = "0755";
                };
                user = lib.mkOption {
                  type = lib.types.str;
                  default = "root";
                };
                group = lib.mkOption {
                  type = lib.types.str;
                  default = "root";
                };
              };
            }
          );
          default = [ ];
          description = "Subdirectories under the backing store (e.g. var/log/audit).";
        };
      };
    }
  );

  backing =
    entry: if lib.hasPrefix "/" entry.store then entry.store else "${cfg.persistPath}/${entry.store}";

  tmpfilesFor =
    method: entry:
    let
      parentRules = map (
        p:
        "d ${
          if lib.hasPrefix "/" p.store then p.store else "${cfg.persistPath}/${p.store}"
        } ${p.mode} ${p.user} ${p.group} -"
      ) entry.parents;
      backingRule =
        if entry.kind == "file" then

          null
        else
          "d ${backing entry} ${entry.mode} ${entry.user} ${entry.group} -";
      childRules = map (
        c: "d ${backing entry}/${c.name} ${c.mode} ${c.user} ${c.group} -"
      ) entry.children;
      linkRule = lib.optional (method == "link") "L+ ${entry.path} - - - - ${backing entry}";
      rules = parentRules ++ lib.optional (backingRule != null) backingRule ++ childRules ++ linkRule;
    in
    rules;

  failedMountRetry = (import ../runtime/nfs-retry.nix { inherit lib; }).mkFailedMountRetry {
    inherit pkgs;
  };
in
{
  options.paxos.ephemeral = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ephemeral tmpfs root (`/` in RAM, state under `/persist`).
        Default on for erase-your-darlings; durable hosts set enable = false.
      '';
    };

    persistPath = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = "Persistent state root (`/persist/{secrets,ssh,caddy,containers,…}`).";
    };

    rootSize = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = ''
        Size limit for the ephemeral tmpfs root filesystem.

        On erase-your-darlings guests, modules/hardware/qemu-guest.nix passes
        this straight through to disko-eyd, because disko -- not NixOS --
        mounts `/` there. Setting it here is the whole change. A mismatch is
        an eval error, not a silently ignored option.
      '';
    };

    binds = lib.mkOption {
      type = lib.types.listOf persistEntry;
      default = [ ];
      description = ''
        neededForBoot bind-mounts from persist onto the tmpfs root.
        Identity and logs that must exist before userspace.
      '';
    };

    links = lib.mkOption {
      type = lib.types.listOf persistEntry;
      default = [ ];
      description = ''
        systemd-tmpfiles L+ from a persist backing path onto the live path.
        For services that start after tmpfiles (NetworkManager, timesync, …).
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.paxos.artifact != "image" || placed;
          message = "paxos.artifact = \"image\" requires paxos.spec.id";
        }

        {
          assertion =
            let
              mountOpts = lib.attrByPath [ "disko" "devices" "nodev" "/" "mountOptions" ] null config;
              sized = lib.filter (o: lib.hasPrefix "size=" o) (if mountOpts == null then [ ] else mountOpts);
              diskoSize = lib.removePrefix "size=" (lib.head (sized ++ [ "" ]));
            in
            sized == [ ] || diskoSize == cfg.rootSize;
          message = ''
            paxos.ephemeral.rootSize = "${cfg.rootSize}" but disko mounts / at a
            different size. On erase-your-darlings guests qemu-guest.nix passes
            this option to disko-eyd; a hand-written disk layout has to use the
            same size.
          '';
        }
      ];
    }
    (lib.mkIf cfg.enable {
      fileSystems = {
        "/" = lib.mkDefault {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [
            "defaults"
            "size=${cfg.rootSize}"
            "mode=755"
            "nosuid"
            "nodev"
          ];
          neededForBoot = true;
        };
        "/nix".neededForBoot = lib.mkDefault true;

        "${cfg.persistPath}" = {
          device = lib.mkDefault "/nix/persist";
          fsType = lib.mkDefault "none";
          options = lib.mkDefault [ "bind" ];
          depends = [ "/nix" ];
          neededForBoot = true;
        };
      }
      // lib.listToAttrs (
        map (entry: {
          name = entry.path;

          value = {
            device = backing entry;
            fsType = "none";
            options = [
              "bind"
            ]
            ++ lib.optionals entry.neededForBoot [
              "x-systemd.requires=mkdir-nix-persist.service"
              "x-systemd.after=mkdir-nix-persist.service"
            ]
            ++ lib.optional (entry.kind == "file") "X-mount.mkdir=no";
            inherit (entry) neededForBoot;
            depends = lib.mkIf (lib.hasPrefix cfg.persistPath (backing entry)) [ cfg.persistPath ];
          };
        }) cfg.binds
      );

      boot.initrd.systemd.services.mkdir-nix-persist = {
        description = "Create /nix/persist for ephemeral root";

        wantedBy = [ "initrd-fs.target" ];
        requiredBy = [
          "sysroot-persist.mount"
          "sysroot-etc-machine\\x2did.mount"
          "sysroot-var-log.mount"
        ];
        before = [
          "sysroot-persist.mount"
          "sysroot-etc-machine\\x2did.mount"
          "sysroot-var-log.mount"
          "initrd-fs.target"
        ];
        after = [ "sysroot-nix.mount" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          mkdir -p /sysroot/nix/persist/etc /sysroot/nix/persist/var/log/audit \
            /sysroot/nix/persist/secrets /sysroot/etc /sysroot/var/log
          chmod 700 /sysroot/nix/persist/secrets
          chmod 700 /sysroot/nix/persist/var/log/audit

          write_mid() {
            uuid=$(cat /proc/sys/kernel/random/uuid)
            a=''${uuid%%-*}; rest=''${uuid#*-}
            b=''${rest%%-*}; rest=''${rest#*-}
            c=''${rest%%-*}; rest=''${rest#*-}
            d=''${rest%%-*}; e=''${rest#*-}
            printf '%s' "$a$b$c$d$e" > "$1"
            chmod 644 "$1"
          }

          mid=/sysroot/nix/persist/etc/machine-id
          if [ -d "$mid" ]; then
            rm -rf "$mid"
          fi
          if [ ! -s "$mid" ]; then
            write_mid "$mid"
          fi

          dst=/sysroot/etc/machine-id
          if [ -d "$dst" ]; then
            rm -rf "$dst"
          fi
          cp "$mid" "$dst"
          chmod 644 "$dst"
        '';
      };

      systemd.services.paxos-bind-var-log = {
        description = "Bind persist logs onto /var/log if fstab did not";
        wantedBy = [ "multi-user.target" ];
        after = [ "persist.mount" ];
        path = [
          pkgs.util-linux
          pkgs.coreutils
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          mkdir -p /persist/var/log/audit /var/log
          chmod 700 /persist/var/log/audit
          if ! findmnt -n /var/log >/dev/null 2>&1; then
            echo "paxos-bind-var-log: bind /persist/var/log → /var/log"
            mount --bind /persist/var/log /var/log
          fi
        '';
      };

      systemd.services.systemd-machine-id-commit.enable = false;

      system.activationScripts.paxosPersistOwn = lib.stringAfter [ "paxosPinIds" ] ''
        ${lib.concatMapStringsSep "\n" (
          entry:
          let
            dir = lib.escapeShellArg (backing entry);
            own = "${entry.user}:${entry.group}";
          in
          ''
            if [ -d ${dir} ]; then
              chown ${own} ${dir}
              ${lib.optionalString (entry.user != "root") "chown -R ${own} ${dir}"}

              for sub in ${dir}/*; do
                [ -d "$sub" ] || continue
                u=$(stat -c %U "$sub" 2>/dev/null) || continue
                [ "$u" = root ] && continue
                g=$(stat -c %G "$sub" 2>/dev/null) || continue
                chown -R "$u:$g" "$sub"
              done
            fi
          ''
        ) (cfg.binds ++ cfg.links)}
      '';

      systemd.services.paxos-nfs-retry = failedMountRetry.service;
      systemd.timers.paxos-nfs-retry = failedMountRetry.timer;

      systemd.tmpfiles.rules = [
        "d ${cfg.persistPath} 0755 root root -"
        "d ${cfg.persistPath}/secrets 0700 root root -"
        "d ${cfg.persistPath}/ssh 0755 root root -"
        "d ${cfg.persistPath}/containers 0755 root root -"
        "d ${cfg.persistPath}/etc 0755 root root -"
        "d ${cfg.persistPath}/var 0755 root root -"
        "d ${cfg.persistPath}/var/lib 0755 root root -"
        "d ${cfg.persistPath}/var/log 0755 root root -"
        "d ${cfg.persistPath}/var/log/audit 0700 root root -"
      ]
      ++ lib.concatMap (tmpfilesFor "bind") cfg.binds
      ++ lib.concatMap (tmpfilesFor "link") cfg.links;
    })
  ];
}
