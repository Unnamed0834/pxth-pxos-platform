{
  config,
  lib,
  ...
}:

let
  cfg = config.paxos.exec;
  persistRoot = config.paxos.ephemeral.persistPath;
  enabledUnits = lib.filterAttrs (_: u: u.enable) cfg.units;
  persistEnabled = config.paxos.ephemeral.enable or false;
  runtimeDir =
    dir:
    let
      rel = lib.removePrefix "/var/lib/" dir;
    in
    "${persistRoot}/runtime/${rel}";
in
{
  options.paxos.exec = {
    nixLd = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable nix-ld so upstream dynamically linked binaries (not Nix-built)
        can run on L1. Workloads may add libraries via programs.nix-ld.libraries.
      '';
    };

    persistDirs = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "/var/lib/[^[:space:]]+");
      default = [ ];
      description = ''
        Absolute /var/lib paths rebound onto ${persistRoot}/runtime.
        Survives tmpfs-as-root.
      '';
    };

    persistDirOwner = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        "user:group" for a persistDirs entry. Unlisted paths stay root.
      '';
    };

    units = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }: {
            options = {
              enable = lib.mkEnableOption "systemd unit ${name}" // {
                default = true;
              };

              description = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "systemd Description";
              };

              command = lib.mkOption {
                type = lib.types.nonEmptyListOf lib.types.str;
                description = "ExecStart argv (store paths or PATH binaries)";
              };

              user = lib.mkOption {
                type = lib.types.str;
                default = "operator";
                description = "Service User";
              };

              group = lib.mkOption {
                type = lib.types.str;
                default = "users";
                description = "Service Group";
              };

              environment = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
                description = "Environment variables";
              };

              environmentFile = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Optional EnvironmentFile (secrets in tmpfs)";
              };

              workingDirectory = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "WorkingDirectory";
              };

              after = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "network-online.target" ];
                description = "Units to start after";
              };

              wants = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "network-online.target" ];
                description = "Units to want";
              };

              memory = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "MemoryMax (e.g. 8G)";
              };

              restart = lib.mkOption {
                type = lib.types.str;
                default = "on-failure";
                description = "Restart policy";
              };
            };
          }
        )
      );
      default = { };
      description = "Declarative systemd units for exec-runtime binaries";
    };
  };

  config = {
    assertions = [
      {
        assertion = !(config.virtualisation.podman.enable or false);
        message = "exec runtime forbids the podman engine; use SPEC runtime=podman";
      }
    ];

    programs.nix-ld.enable = lib.mkDefault cfg.nixLd;

    systemd.services = lib.mapAttrs (_name: u: {
      inherit (u) description;
      wantedBy = [ "multi-user.target" ];
      inherit (u) after;
      inherit (u) wants;
      inherit (u) environment;
      serviceConfig = {
        Type = "exec";
        User = u.user;
        Group = u.group;
        ExecStart = lib.escapeShellArgs u.command;
        Restart = u.restart;
        RestartSec = "5s";
      }
      // lib.optionalAttrs (u.workingDirectory != null) {
        WorkingDirectory = u.workingDirectory;
      }
      // lib.optionalAttrs (u.environmentFile != null) {
        EnvironmentFile = u.environmentFile;
      }
      // lib.optionalAttrs (u.memory != null) {
        MemoryMax = u.memory;
      };
    }) enabledUnits;

    systemd.tmpfiles.rules = lib.concatMap (
      dir:
      let
        own = cfg.persistDirOwner.${dir} or "root:root";
        parts = lib.splitString ":" own;
        user = lib.head parts;
        group = lib.last parts;
        dest = runtimeDir dir;
      in
      if persistEnabled then
        [
          "d ${dest} 0755 ${user} ${group} -"
          "L+ ${dir} - - - - ${dest}"
        ]
      else
        [
          "d ${dir} 0755 ${user} ${group} -"
        ]
    ) cfg.persistDirs;
  };
}
