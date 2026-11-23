
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.paxos.workloads.forgejo;
  inherit (cfg) httpPort;
  eyd = config.paxos.ephemeral.enable;
  resticEdge = import ../plugins/restic-edge.nix { inherit config lib; };
  pgSchema = config.services.postgresql.package.psqlSchema;
  forgePersist = "/persist/var/lib/forgejo";
  pgPersist = "/persist/var/lib/postgresql";
in
{
  options.paxos.workloads.forgejo = {
    enable = lib.mkEnableOption "Forgejo git forge (nixpkgs services.forgejo)";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "git.example.com";
      description = "Public hostname (DOMAIN / ROOT_URL).";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Loopback HTTP port for Caddy → Forgejo.";
    };

    disableRegistration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable open registration (create admin once, then keep locked).";
    };
  };

  config = lib.mkIf cfg.enable {
    paxos.cover.defaultBackend = "127.0.0.1:${toString httpPort}";
    paxos.cover.resticHold = [
      "forgejo.service"
      "forgejo-secrets.service"
      "postgresql.service"
    ];
    paxos.cover.resticPaths = [ forgePersist ];

    services.forgejo = {
      enable = true;

      stateDir = lib.mkIf eyd forgePersist;
      database.type = "postgres";
      lfs.enable = true;
      settings = {
        server = {
          DOMAIN = cfg.domain;
          ROOT_URL = "https://${cfg.domain}/";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = httpPort;

          START_SSH_SERVER = true;
          SSH_LISTEN_PORT = 2222;
          SSH_DOMAIN = cfg.domain;
        };
        service.DISABLE_REGISTRATION = cfg.disableRegistration;
        actions.ENABLED = true;
      };
    };

    services.postgresql = {

      package = pkgs.postgresql_18;
      dataDir = lib.mkIf eyd "${pgPersist}/${pgSchema}";
    };

    systemd.services.postgresql.serviceConfig.StateDirectory = lib.mkIf eyd (lib.mkForce [ ]);

    systemd.tmpfiles.rules = lib.mkIf eyd [
      "d /persist/var/lib 0755 root root -"
      "d ${forgePersist} 0750 forgejo forgejo -"
      "d ${pgPersist} 0750 postgres postgres -"
      "d ${pgPersist}/${pgSchema} 0750 postgres postgres -"
    ];

    systemd.services.forgejo-secrets.after = [ "restic-bootstrap.service" ];

    systemd.services.forgejo.after = resticEdge;
    systemd.services.forgejo.wants = resticEdge;
  };
}
