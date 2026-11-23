{
  config,
  lib,
  pkgs,
  ...
}:

{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;

    daemon.settings."no-new-privileges" = true;
  };
  virtualisation.oci-containers.backend = "docker";
  environment.systemPackages = [ pkgs.docker-compose ];

  paxos.ephemeral.links = lib.mkIf config.paxos.ephemeral.enable [
    {
      path = "/var/lib/docker";
      store = "/persist/var/lib/docker";
      mode = "0710";
      parents = [
        {
          store = "/persist/var";
          mode = "0755";
        }
        {
          store = "/persist/var/lib";
          mode = "0755";
        }
      ];
    }
  ];
}
