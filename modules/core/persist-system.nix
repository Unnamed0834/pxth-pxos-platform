{
  config,
  lib,
  ...
}:

{
  config = lib.mkIf config.paxos.ephemeral.enable {
    paxos.ephemeral.binds = [
      {
        path = "/etc/machine-id";
        store = "/persist/etc/machine-id";
        kind = "file";
        mode = "0644";
        neededForBoot = true;
        parents = [
          {
            store = "/persist/etc";
            mode = "0755";
          }
        ];
      }
      {
        path = "/var/log";
        store = "/persist/var/log";
        mode = "0755";
        neededForBoot = false;
        parents = [
          {
            store = "/persist/var";
            mode = "0755";
          }
        ];
        children = [
          {
            name = "audit";
            mode = "0700";
          }
        ];
      }
    ];

    paxos.ephemeral.links = [
      {
        path = "/var/db/sudo/lectured";
        store = "/persist/var/db/sudo/lectured";
        mode = "0700";
        parents = [
          {
            store = "/persist/var";
            mode = "0755";
          }
          {
            store = "/persist/var/db";
            mode = "0755";
          }
          {
            store = "/persist/var/db/sudo";
            mode = "0700";
          }
        ];
      }

    ];

    system.activationScripts.removeTimesyncSymlink = lib.stringAfter [ "etc" ] ''
      if [ -L /var/lib/systemd/timesync ]; then
        rm -f /var/lib/systemd/timesync
      fi
    '';
  };
}
