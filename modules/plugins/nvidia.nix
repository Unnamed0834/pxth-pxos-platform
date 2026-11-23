
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.paxos.plugins.nvidia;
  capPairs = lib.mapAttrsToList (idx: watts: {
    inherit idx watts;
  }) cfg.powerCapWatts;

  nvidiaSmi = (import ../runtime/nvidia-smi.nix { inherit pkgs lib; }) config.hardware.nvidia.package;
  applyCaps = pkgs.writeShellScript "nvidia-powercap" ''
    set -euo pipefail
    if ! ${nvidiaSmi} -L >/dev/null 2>&1; then
      echo "NVIDIA driver not ready; power limits apply on next boot"
      exit 0
    fi
    ${nvidiaSmi} -pm 1
    ${lib.concatMapStrings (p: ''
      ${nvidiaSmi} -i ${toString p.idx} -pl ${toString p.watts}
    '') capPairs}
  '';
in
{
  options.paxos.plugins.nvidia = {
    enable = lib.mkEnableOption "NVIDIA proprietary/open drivers";

    open = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use open kernel modules when true";
    };

    powerCapWatts = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = { };
      example = {
        "0" = 100;
        "1" = 100;
        "2" = 200;
        "3" = 200;
      };
      description = "Persistent nvidia-smi power limit per GPU index (watts).";
    };

    kernelParams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nvidia-drm.modeset=1"
        "nvidia-drm.fbdev=1"

        "lockdown=none"
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelParams = lib.mkAfter cfg.kernelParams;

    hardware.nvidia = {
      modesetting.enable = true;
      powerManagement.enable = false;
      powerManagement.finegrained = false;
      inherit (cfg) open;
      nvidiaSettings = true;
    };

    services.xserver.videoDrivers = [ "nvidia" ];

    systemd.services.nvidia-powercap = lib.mkIf (cfg.powerCapWatts != { }) {
      description = "Apply SPEC NVIDIA power limits";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = applyCaps;
      };
    };
  };
}
