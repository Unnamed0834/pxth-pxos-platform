_:
let
  site = import ../../../modules/sites/site-a.nix;
in
{
  imports = [
    (import ../../../modules/platform/guest.nix {
      specId = "app-portal";
      inherit (site) domain;
      address = "198.51.100.28";
      vlan = 3008;
      cores = 2;
      memory = 4096;
      diskGiB = 100;
      imageSize = "16G";
      firewall.tcp = [
        80
        443
      ];
      wazuhAgent = false;
    })
  ];

  system.stateVersion = "26.11";
}
