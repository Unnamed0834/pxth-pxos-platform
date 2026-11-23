{
  config,
  lib,
  ...
}:


let
  enabled = config.paxos.ephemeral.enable;
in
{
  config = lib.mkMerge [
    (lib.mkIf (enabled && config.networking.networkmanager.enable) {
      paxos.ephemeral.links = [
        {
          path = "/etc/NetworkManager/system-connections";
          mode = "0700";
          parents = [
            {
              store = "etc/NetworkManager";
              mode = "0755";
            }
          ];
        }
        {
          path = "/var/lib/NetworkManager";
          mode = "0700";
        }
      ];
    })
    (lib.mkIf (enabled && config.hardware.bluetooth.enable) {
      paxos.ephemeral.links = [
        {
          path = "/var/lib/bluetooth";
          mode = "0700";
        }
      ];
    })
  ];
}
