
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.paxos.plugins.devtools;
in
{
  options.paxos.plugins.devtools = {
    enable = lib.mkEnableOption "developer / operator host packages";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.age
      pkgs.code-server
      pkgs.ansible
      pkgs.opentofu

      (pkgs.callPackage ../packages/opencode-v2.nix { })
      pkgs.git
      pkgs.nodejs_22
      pkgs.rustc
      pkgs.cargo
      pkgs.go
      pkgs.restic
      pkgs.firecracker
      pkgs.btop
      pkgs.butane
      pkgs.util-linux
      pkgs.kubectl
      pkgs.helmfile
      pkgs.k9s
      pkgs.terragrunt
      pkgs.pulumi
      pkgs.just
      pkgs.direnv
      pkgs.awscli2
      pkgs.gnumake
      pkgs.lsof
      pkgs.htop
      pkgs.fastfetch
      pkgs.samba
      pkgs.cifs-utils
      pkgs.gnupg
      pkgs.ffmpeg
      (pkgs.python3.withPackages (ps: [
        ps.pyyaml
        ps.huggingface-hub
        ps.pillow
      ]))
    ];
  };
}
