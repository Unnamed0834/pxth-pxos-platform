{
  lib,
  config,
  ...
}:


let
  ipv4 = "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}";


  records = lib.concatLists (
    lib.mapAttrsToList (
      iface: i:
      map (a: {
        inherit iface;
        inherit (a) address;
        prefixLength = a.prefixLength or 24;
      }) (i.ipv4.addresses or [ ])
    ) config.networking.interfaces
  );

  shown = map (r: "${r.iface}.${r.address}/${toString r.prefixLength}") records;
  addrStrings = map (r: r.address) records;
  dupes = lib.filter (a: lib.count (v: v == a) addrStrings > 1) addrStrings;
  gw = config.networking.defaultGateway.address or null;
in
{
  config = {

    assertions = [
      {
        assertion = builtins.all (r: builtins.match ipv4 r.address != null) records;
        message =
          "every static address must be a dotted-quad IPv4 literal, got: "
          + builtins.concatStringsSep ", " shown;
      }
      {

        assertion = builtins.all (r: builtins.match "[0-9.]+$" r.address != null) records;
        message =
          "static addresses must not carry a prefix (write address and prefixLength separately), got: "
          + builtins.concatStringsSep ", " shown;
      }
      {
        assertion = builtins.all (r: r.prefixLength >= 0 && r.prefixLength <= 32) records;
        message = "prefixLength must be 0-32, got: " + builtins.concatStringsSep ", " shown;
      }
      {


        assertion = dupes == [ ];
        message = "duplicate static address on this host: " + builtins.concatStringsSep ", " dupes;
      }
      {
        assertion = gw == null || builtins.match ipv4 gw != null;
        message =
          "networking.defaultGateway.address must be a dotted-quad IPv4 literal, got: "
          + (if gw == null then "<unset>" else gw);
      }
    ];

    networking.useNetworkd = lib.mkDefault (!config.networking.networkmanager.enable);
    networking.networkmanager.enable = lib.mkDefault false;

    networking.nftables.enable = lib.mkDefault true;

    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ ];
      allowedUDPPortRanges = [ ];
    };

    systemd.network.wait-online = {
      anyInterface = true;
      ignoredInterfaces = [ "lo" ];
    };
  };
}
