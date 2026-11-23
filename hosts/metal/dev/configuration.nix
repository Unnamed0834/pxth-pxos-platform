{
  imports = [
    ../../../modules/platform/base.nix
    ../../../modules/platform/metal-gc.nix
    ../../../modules/plugins/firewall.nix
    ../disk-config.nix
  ];

  system.stateVersion = "26.11";

  paxos.wazuhAgent.enable = false;
  paxos.ephemeral.enable = false;
  paxos.spec.id = "dev";
}
