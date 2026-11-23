{
  specId,
  domain,
  address,
  vlan,
  vmid ? null,
  imports ? [ ],
  node ? null,
  cores,
  memory,
  diskGiB,
  imageSize,
  swapGiB ? 0,
  balloon ? true,
  qemuExtraConf ? {
    cpu = "host";
  },
  firewall,
  wazuhAgent ? true,
}:
let
  vmidLib = import ../runtime/vmid.nix;
  octets = vmidLib.parseAddress address;
  badAddr = octets == null;
  derivedVmid =
    if badAddr then
      throw "guest ${specId}: address must be a dotted IPv4, got ${address}"
    else
      vmidLib.vmid { inherit vlan address; };
  vmidFinal = if vmid == null then derivedVmid else vmid;
  expectedPrefix = "198.51.100";
  actualPrefix =
    if badAddr then
      ""
    else
      "${builtins.elemAt octets 0}.${builtins.elemAt octets 1}.${builtins.elemAt octets 2}";
in
{ lib, ... }: {
  imports = [
    ./base.nix
    ../hardware/qemu-guest.nix
    ../plugins/firewall.nix
    (import ../hardware/guest-net.nix {
      hostName = specId;
      inherit address domain;
    })
  ]
  ++ imports;

  assertions = [
    {
      assertion = vmidFinal == derivedVmid;
      message = ''
        guest ${specId}: vmid ${toString vmidFinal} breaks the fleet
        convention vmid = vlan*100 + last octet of the address —
        ${toString derivedVmid} for VLAN ${toString vlan} at ${address}.
      '';
    }
    {
      assertion = !badAddr && actualPrefix == expectedPrefix;
      message = ''
        guest ${specId}: address ${address} is outside the VLAN
        ${toString vlan} subnet ${expectedPrefix}.0/24.
      '';
    }
  ];

  paxos = {
    wazuhAgent.enable = wazuhAgent;
    spec.id = specId;
    pve = {
      enable = true;
      vmid = vmidFinal;
      inherit
        vlan
        cores
        memory
        diskGiB
        imageSize
        swapGiB
        balloon
        qemuExtraConf
        ;
    }
    // (if node == null then { } else { inherit node; });
    plugins = {
      firewall = {
        enable = true;
      }
      // firewall;
      ssh.allowFrom = lib.mkDefault [
        "192.0.2.10"
        "198.51.100.21"
        "198.51.100.22"
      ];
      ssh.extraAllowUsers = [
        "ops@198.51.100.21"
        "ops@198.51.100.22"
      ];
    };
  };
}
