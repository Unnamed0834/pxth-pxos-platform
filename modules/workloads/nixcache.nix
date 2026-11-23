
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.paxos.nixCache;
  alertProbe = import ../runtime/alert-probe.nix { inherit pkgs lib; };
  cacheProbe = alertProbe {
    name = "paxos-cache-probe";
    description = "Page when the fleet binary cache stops answering";
    result = "cache-down";
    fields = "url=${cfg.client.url}";
    check = "timeout 8 nix store ping --store ${lib.escapeShellArg cfg.client.url} >/dev/null 2>&1";
    after = [ "network-online.target" ];
    path = [
      pkgs.coreutils
      pkgs.nix
    ];
    hostname = "hostname -s";
    timerConfig = {
      OnUnitActiveSec = "5min";
      OnBootSec = "1min";
      Persistent = true;
    };
  };
in
{
  options.paxos.nixCache = {
    enable = lib.mkEnableOption "harmonia binary cache serving";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    signKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "agenix file holding the binary-cache secret key (nix-store --generate-binary-cache-key).";
    };

    client = {
      enable = lib.mkEnableOption "use the fleet binary cache as a substituter";

      url = lib.mkOption {
        type = lib.types.str;
        default = "https://cache.example.com";
      };

      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "cache:EXAMPLE_PUBLIC_KEY";
      };

      probe = lib.mkEnableOption "journal when the fleet cache stops answering";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      paxos.cover.defaultBackend = "127.0.0.1:${toString cfg.port}";
      assertions = [
        {
          assertion = cfg.signKeyFile != null;
          message = "paxos.nixCache.signKeyFile is required when the cache serves";
        }
      ];

      age.secrets.cache-sign-key = {
        file = cfg.signKeyFile;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      services.harmonia.cache = {
        enable = true;
        signKeyPaths = [ config.age.secrets.cache-sign-key.path ];
        settings.bind = "[::]:${toString cfg.port}";
      };

      systemd.services.harmonia = {
        after = [ "agenix-decrypt.service" ];
        wants = [ "agenix-decrypt.service" ];
      };

      nix.settings.require-sigs = false;
    })
    (lib.mkIf cfg.client.enable {
      nix.settings = {

        substituters = lib.mkOrder 400 [ cfg.client.url ];
        trusted-public-keys = [ cfg.client.publicKey ];

        fallback = true;
      };
    })
    (lib.mkIf (cfg.client.enable && cfg.client.probe) {
      systemd.services.paxos-cache-probe = cacheProbe.service;
      systemd.timers.paxos-cache-probe = cacheProbe.timer;
    })
  ];
}
