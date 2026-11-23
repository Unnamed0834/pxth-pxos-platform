{ lib, ... }:
{
  options.paxos.plugins.restic = {
    enable = lib.mkEnableOption "restic backups";
    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    postgres = lib.mkOption {
      type = lib.types.submodule {
        options = {
          dumpDir = lib.mkOption {
            type = lib.types.str;
            default = "/persist/var/lib/restic-pgdump";
          };
          databases = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
      };
      default = { };
    };
  };
}
