{ lib, ... }:

{
  options.paxos.ssh = {
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEKEYMATERIALPLACEHOLDER operator@example.com"
      ];
      description = "Authorized SSH public keys for the operator account (fleet default: one placeholder key; hosts may override).";
    };
  };
}
