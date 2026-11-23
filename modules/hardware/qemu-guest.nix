

{
  config,
  lib,
  ...
}:
{
  imports = [
    (import ./disko-eyd.nix {
      device = "/dev/sda";
      rootSize = config.paxos.ephemeral.rootSize;
    })
  ];

  services.qemuGuest.enable = lib.mkDefault true;
  hardware.enableRedistributableFirmware = lib.mkDefault true;
  boot.initrd.availableKernelModules = [
    "virtio_blk"
    "virtio_pci"
    "virtio_scsi"
    "virtio_net"
    "virtio_balloon"
    "uas"
  ];


  boot.kernelModules = [ "virtio_balloon" ];
}
