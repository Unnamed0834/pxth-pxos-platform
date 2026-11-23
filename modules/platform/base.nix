


{
  lib,
  config,
  pkgs,
  ...
}:
{
  imports = [
    ./persist-paths.nix
    ./cover.nix
    ../core
    ../plugins/restic.nix
    ./nix-gc.nix
    ./ssh.nix
    ./ops.nix
    ./upgrade.nix
    ./shell.nix
    ./console.nix
    ../hardware/pve-vma.nix
    ./wazuh-agent.nix
  ];

  paxos.ephemeral.enable = lib.mkDefault true;
  paxos.wazuhAgent.enable = lib.mkDefault true;


  paxos.artifact = lib.mkDefault "image";
  paxos.plugins.ssh.enable = lib.mkDefault true;

  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.systemd-boot.enable = lib.mkDefault true;

  boot.loader.systemd-boot.bootCounting.enable = lib.mkDefault true;

  boot.loader.systemd-boot.bootCounting.tries = lib.mkDefault 3;
  boot.loader.efi.efiSysMountPoint = lib.mkDefault "/boot";

  boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

  systemd.services.systemd-bless-boot.enable = lib.mkIf config.boot.loader.systemd-boot.bootCounting.enable false;
  systemd.services.paxos-bless-boot =
    let
      waitForSsh = config.paxos.plugins.ssh.enable;
      bless = pkgs.writeShellScript "paxos-bless-boot" ''
        set -euo pipefail
        out=$(${pkgs.systemd}/lib/systemd/systemd-bless-boot good 2>&1) || {
          case "$out" in
            *"Not booted with boot counting"*|*"Can't find boot counter source file"*) exit 0 ;;
          esac
          printf '%s\n' "$out" >&2
          exit 1
        }
      '';
    in
    lib.mkIf config.boot.loader.systemd-boot.bootCounting.enable {
      description = "Mark this boot good once the host is reachable";
      wantedBy = [ "multi-user.target" ];
      after = if waitForSsh then [ "sshd.service" ] else [ ];
      requires = if waitForSsh then [ "sshd.service" ] else [ ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = bless;
      };
    };

  systemd.tmpfiles.rules = lib.mkIf (!config.paxos.ephemeral.enable) [
    "d /persist 0755 root root -"
    "d ${config.paxos.persist.secretsDir} 0700 root root -"
    "d ${config.paxos.persist.sshDir} 0755 root root -"
  ];

  age.identityPaths = lib.mkDefault [
    "${config.paxos.persist.secretsDir}/key.txt"
  ];
}
