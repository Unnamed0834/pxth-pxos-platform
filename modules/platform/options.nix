
{
  lib,
  config,
  ...
}:
{
  options.paxos.spec.id = lib.mkOption {
    type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9_.-]{1,128}");
    default = null;
    description = "Host id (hostname metadata / etc/paxos/spec).";
  };

  options.paxos.artifact = lib.mkOption {
    type = lib.types.enum [
      "platform"
      "image"
    ];
    default = "platform";
    description = "image when workloads/plugins are composed; otherwise bare base. Hosts importing platform/base.nix default to image; the installer ISO stays platform.";
  };

  config = {
    system.nixos.distroId = "paxos";
    system.nixos.distroName = "pxOS";
    environment.etc."paxos/spec" = lib.mkIf (config.paxos.spec.id != null) {
      text = "${config.paxos.spec.id}\n";
    };
  };
}
