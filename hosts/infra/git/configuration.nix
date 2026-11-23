_:
let
  site = import ../../../modules/sites/site-a.nix;
in
{
  imports = [
    (import ../../../modules/platform/guest.nix {
      specId = "git";
      inherit (site) domain;
      address = "198.51.100.21";
      vlan = 3001;
      imports = [
        ../../../modules/workloads/forgejo.nix
      ];
      cores = 2;
      memory = 4096;
      diskGiB = 100;
      imageSize = "16G";
      firewall.tcp = [
        80
        443
        2222
      ];
      wazuhAgent = false;
    })
  ];

  system.stateVersion = "26.11";

  paxos.workloads.forgejo = {
    enable = true;
    domain = "git.example.com";
  };
}
