{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.paxos.workloads.code-server;
  passwordFile = "/run/agenix/code-server-password";
  resticEdge = import ../plugins/restic-edge.nix { inherit config lib; };
  codeServer = pkgs.code-server;
in
{
  options.paxos.workloads.code-server = {
    enable = lib.mkEnableOption "code-server IDE";
    secretFile = lib.mkOption {
      type = lib.types.path;
      description = "Age-encrypted password file.";
    };
  };

  config = lib.mkIf cfg.enable {
    paxos.cover.backends.code = "127.0.0.1:8080";

    age.secrets.code-server-password = {
      file = cfg.secretFile;
      mode = "0400";
    };

    users.groups.ide = { };
    users.users.ide = {
      isSystemUser = true;
      group = "ide";
      home = "/home/operator/workspace";
      createHome = true;
    };
    systemd.tmpfiles.rules = [ "d /home/operator/workspace 0755 ide ide -" ];

    systemd.services.code-server = {
      description = "code-server IDE";
      wantedBy = [ "multi-user.target" ];

      wants = [ "network-online.target" ] ++ resticEdge;
      after = [ "network-online.target" ] ++ resticEdge;
      serviceConfig = {
        Type = "simple";
        User = "ide";
        Group = "ide";
        UMask = "0002";
        ExecStart = "${codeServer}/bin/code-server --config /etc/code-server/config.yaml";
        Restart = "on-failure";
        RestartSec = 5;
        WorkingDirectory = "/home/operator/workspace";
        RuntimeDirectory = "code-server";
        EnvironmentFile = passwordFile;
      };

      environment.SHELL = "${pkgs.zsh}/bin/zsh";
    };

    environment.etc."code-server/config.yaml".text = ''
      bind-addr: 127.0.0.1:8080
      auth: password
      cert: false
    '';
  };
}
