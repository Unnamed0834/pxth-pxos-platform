

{
  config,
  lib,
  ...
}:
let
  cfg = config.paxos.releaseVerify;


  keyRe = "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) AAAA[A-Za-z0-9+/=]+( .*)?";
in
{
  options.paxos.releaseVerify = {
    enable = lib.mkEnableOption "the paxos-ops-switch release signature check";

    publicKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLERELEASEKEY paxos-release";
      description = "OpenSSH public key line used to verify release signatures when enable is true.";
    };
  };

  config = {
    paxos.releaseVerify = {
      enable = true;
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLERELEASEKEY paxos-release";
    };

    assertions = [
      {
        assertion = !cfg.enable || builtins.match keyRe cfg.publicKey != null;
        message = "paxos.releaseVerify.publicKey must be one OpenSSH public key line when release verification is enabled";
      }
    ];
  };
}
