{
  config,
  lib,
  ...
}:


let
  cfg = config.paxos.autoUpgrade;
in
{
  options.paxos.autoUpgrade = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the systemd nixos-upgrade timer. Does nothing unless flake is also set.";
    };

    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "git+https://git.example.com/example/pxOS";
      description = ''
        Flake URL without `#attr`. Null leaves the timer off even when enable
        is true. A `path:` store path does not refresh.
        Attr comes from `configuration`.
      '';
    };

    configuration = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "nixosConfigurations attribute to rebuild.";
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "04:40";
      description = "systemd calendar for nixos-upgrade.service.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "45min";
    };

    allowReboot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Reboot after a successful online upgrade.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.flake != null) {
    system.autoUpgrade = {
      enable = true;
      flake = "${cfg.flake}#${cfg.configuration}";
      flags = [ "--refresh" ];
      inherit (cfg) dates;
      inherit (cfg) randomizedDelaySec;
      inherit (cfg) allowReboot;
    };
  };
}
