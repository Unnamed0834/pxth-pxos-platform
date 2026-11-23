
{
  config,
  lib,
  ...
}:
let
  cfg = config.paxos.plugins.firewall;
in
{
  options.paxos.plugins.firewall = {
    enable = lib.mkEnableOption "SPEC-driven firewall allowlists";

    tcp = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
    };

    udp = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall = {
      enable = true;
      allowedTCPPorts = cfg.tcp;
      allowedUDPPorts = cfg.udp;
    };
  };
}
