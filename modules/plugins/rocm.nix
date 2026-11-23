
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.paxos.plugins.rocm;
in
{
  options.paxos.plugins.rocm = {
    enable = lib.mkEnableOption "AMD ROCm / amdgpu";

    gfxVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional HSA_OVERRIDE_GFX_VERSION (e.g. 11.0.0 for gfx1103)";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.amdgpu = {
      initrd.enable = true;
      opencl.enable = true;
    };

    environment.systemPackages = [
      pkgs.rocmPackages.rocminfo
      pkgs.rocmPackages.rocm-smi
    ];

    users.users.operator.extraGroups = [ "render" ];

    environment.sessionVariables = lib.mkIf (cfg.gfxVersion != null) {
      HSA_OVERRIDE_GFX_VERSION = cfg.gfxVersion;
    };
  };
}
