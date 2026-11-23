
{
  pkgs,
  lib,
  config,
}:
let
  rootless = import ./rootless-pod.nix { inherit pkgs lib config; };
  images = import ./images.nix;
  inherit (rootless) podman runner;
  harden = import ./container-harden.nix;
in
{
  inherit podman runner;

  volFlags = volumes: lib.concatMapStringsSep " " (v: "-v ${v}") volumes;

  cvols =
    cfg: defaults: name:
    let
      override = (cfg.containers.${name} or { }).volumes or null;
    in
    if override != null then override else (defaults.${name} or [ ]);

  stackOptions =
    {
      enableDescription,
      defaultPorts,
    }:
    {
      enable = lib.mkEnableOption enableDescription;

      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra systemd units this stack starts after (typically automounts)";
      };

      memory = lib.mkOption {
        type = lib.types.str;
        default = "4G";
        description = "systemd MemoryMax for the stack";
      };

      timeoutStartSec = lib.mkOption {
        type = lib.types.str;
        default = "300s";
        description = "systemd TimeoutStartSec for the stack";
      };

      ports = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = defaultPorts;
        description = "Pod port mappings (-p)";
      };

      gluetunEnvFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/secrets/gluetun_env";
        description = "Path to Gluetun --env-file (agenix-planted)";
      };

      containers = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.volumes = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              description = "Volume mounts for this container (null = template named-volume defaults)";
            };
            options.command = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional args after the image";
            };
          }
        );
        default = { };
        description = "Per-container overrides from the host; unset containers keep template defaults";
      };
    };

  service =
    {
      name,
      unitName,
      description,
      cfg,
      podName,
      uidOffset,
      uidCount,
      stopNames,
      execStartPre,
      gluetunName,
      volumes ? [ ],
      defaultVolumeOwner ? 1000,
      volumeOwners ? { },
      gluetunEnv ? [ ],
      extraPodArgs ? [ ],
      timeoutStartSec ? "300s",
    }:
    rootless.service {
      inherit
        name
        unitName
        description
        podName
        uidOffset
        uidCount
        stopNames
        extraPodArgs
        volumes
        defaultVolumeOwner
        volumeOwners
        timeoutStartSec
        ;
      inherit (cfg) ports memory;
      postCreate = execStartPre;
      extraAfter = cfg.after;
      cpuQuota = "250%";
      execStart = harden.run {
        inherit podman;
        name = gluetunName;
        pod = podName;

        ownerCaps = true;
        caps = [
          "NET_ADMIN"
          "NET_RAW"
          "NET_BIND_SERVICE"
        ];
        args =
          "--device /dev/net/tun:/dev/net/tun --env-file ${cfg.gluetunEnvFile}"
          + lib.concatMapStrings (e: " -e ${e}") gluetunEnv;
        image = images.gluetun;
      };
    };
}
