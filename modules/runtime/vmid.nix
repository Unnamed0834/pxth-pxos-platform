
let

  parseAddress = address: builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.([0-9]+)" address;
in
{
  inherit parseAddress;

  vmid =
    {
      vlan,
      address,
    }:
    let
      octets = parseAddress address;
    in
    if octets == null then
      throw "vmid: address must be a dotted IPv4, got ${address}"
    else
      vlan * 100 + builtins.fromJSON (builtins.elemAt octets 3);
}
