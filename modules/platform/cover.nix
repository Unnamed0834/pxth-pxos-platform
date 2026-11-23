

{ lib, ... }: {
  options.paxos.cover = {
    backends = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Proxy name → host:port or URL this host's enabled workloads
        expose. Proxy takes each key as mkDefault. The host adds
        off-box names (auth portals, peer hosts) and exceptions.
      '';
    };

    defaultBackend = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Exact-zone catch-all reverse_proxy target. Proxy takes this as
        mkDefault when set. A host functor that sets defaultBackend wins.
      '';
    };

    resticHold = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Units that write into restic paths. restic-nas concatenates this
        with paxos.plugins.restic.holdUnits and uniques the result.
      '';
    };

    resticPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra filesystem trees to pack. restic-nas concatenates this with
        paxos.plugins.restic.paths. Named container volumes are already
        added when includeContainerVolumes is on.
      '';
    };
  };
}
