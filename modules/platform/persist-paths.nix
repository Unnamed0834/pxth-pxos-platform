{
  config,
  lib,
  ...
}:
{
  options.paxos.persist = {
    secretsDir = lib.mkOption {
      type = lib.types.str;
      description = "Directory for age identity (key.txt).";
    };
    sshDir = lib.mkOption {
      type = lib.types.str;
      description = "Directory for SSH host keys and authorized_keys.";
    };
    caddyDir = lib.mkOption {
      type = lib.types.str;
      description = "Caddy state directory.";
    };
    containersDir = lib.mkOption {
      type = lib.types.str;
      description = "Rootless podman home+storage directory.";
    };
    podmanVolumesDir = lib.mkOption {
      type = lib.types.str;
      description = "Named-volume directory inside the rootless podman storage.";
    };
  };

  config.paxos.persist = {
    secretsDir = lib.mkDefault "/persist/secrets";
    sshDir = lib.mkDefault "/persist/ssh";
    caddyDir = lib.mkDefault "/persist/caddy";
    containersDir = lib.mkDefault "/persist/var/lib/containers";
    podmanVolumesDir = lib.mkDefault "${config.paxos.persist.containersDir}/home/.local/share/containers/storage/volumes";
  };
}
