

{
  hostName,
  domain,
  address,
  prefixLength ? 24,
  interface ? "ens18",
}:
let
  octets = builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.[0-9]+" address;
  gateway =
    if octets == null then
      throw "guest-net: address must be a dotted IPv4, got ${address}"
    else
      "${builtins.elemAt octets 0}.${builtins.elemAt octets 1}.${builtins.elemAt octets 2}.1";
in
{
  networking = {
    inherit hostName domain;
    useDHCP = false;
    interfaces.${interface}.ipv4.addresses = [
      {
        inherit address prefixLength;
      }
    ];
    defaultGateway = {
      address = gateway;
      inherit interface;
    };
    nameservers = [
      gateway
      "1.1.1.1"
    ];
    search = [ domain ];
  };

  systemd.network.networks."40-${interface}" = {
    dns = [
      gateway
      "1.1.1.1"
    ];
    domains = [ domain ];
  };
}
