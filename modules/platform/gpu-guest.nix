{
  specId,
  address,
  imports ? [ ],
  cores,
  memory,
  diskGiB,
  imageSize,
  node ? null,
  swapGiB ? 0,
  balloon ? true,
  firewall,
  qemuExtraConf ? { },
}:
let
  site = import ../sites/site-a.nix;
in
{ ... }: {
  imports = [
    (import ./guest.nix {
      inherit
        specId
        address
        cores
        memory
        diskGiB
        imageSize
        node
        swapGiB
        balloon
        firewall
        ;
      inherit (site) domain;
      vlan = 3003;
      imports = [
        ../runtime/exec.nix
        ../plugins/nvidia.nix
        ../runtime/docker.nix
      ]
      ++ imports;
      qemuExtraConf = {
        cpu = "host";
      }
      // qemuExtraConf;
    })
  ];

  paxos.plugins.nvidia.enable = true;
}
