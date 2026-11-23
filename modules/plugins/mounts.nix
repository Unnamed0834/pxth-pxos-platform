
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.paxos.plugins.mounts;
  ep = import ../runtime/endpoints.nix;

  nfsRetry = (import ../runtime/nfs-retry.nix { inherit lib; }).mkMountRetry {
    mountPoints =
      map (m: toString m.dest) cfg.nfs.exports
      ++ map (share: "${cfg.cifs.mountRoot}/${share}") cfg.cifs.shares;
  };

  nfsOptions = [
    "x-systemd.automount"
    "noauto"
    "x-systemd.idle-timeout=600"
    "_netdev"
    "soft"
    "intr"
    "nosuid"
    "nodev"
    "noexec"
  ]
  ++ nfsRetry.fstabOptions;

  cifsBaseOptions = [
    "uid=${toString cfg.cifs.uid}"
    "gid=${toString cfg.cifs.gid}"
    "iocharset=utf8"
    "vers=3.1.1"
    "sec=ntlmsspi"
    "seal"
    "_netdev"
    "x-systemd.automount"
    "x-systemd.idle-timeout=1min"
    "x-systemd.requires=network-online.target"
    "x-systemd.after=network-online.target"
    "file_mode=0644"
    "dir_mode=0755"
  ]
  ++ nfsRetry.fstabOptions;

  credPath =
    if cfg.cifs.credentialsFile != null then
      cfg.cifs.credentialsFile
    else if cfg.cifs.secretFile != null then
      "/run/agenix/samba-creds"
    else
      null;

  nfsFileSystems = lib.listToAttrs (
    map (
      m:
      let
        dest = toString m.dest;
        src = toString m.src;
        ro = m.ro or false;
        idleTimeout = m.idleTimeout or null;

        server = if m.server != null then m.server else cfg.nfs.server;
        fsType =
          if (m.fsType or null) != null then
            toString m.fsType
          else if ro then
            "nfs4"
          else
            cfg.nfs.fsType;
        opts =
          if ro then
            [
              "ro"
              "noatime"
              "hard"
              "proto=tcp"
              "nofail"
              "x-systemd.automount"
              "x-systemd.idle-timeout=${toString (if idleTimeout == null then 60 else idleTimeout)}"
              nfsRetry.timeoutOption
            ]
          else
            (builtins.filter (o: !(lib.hasPrefix "x-systemd.idle-timeout=" o)) nfsOptions)
            ++ [
              "x-systemd.idle-timeout=${toString (if idleTimeout == null then 600 else idleTimeout)}"
            ];
      in
      lib.nameValuePair dest {
        device = "${server}:${src}";
        inherit fsType;
        options = opts;
      }
    ) cfg.nfs.exports
  );

  cifsFileSystems = lib.listToAttrs (
    map (
      share:
      lib.nameValuePair "${cfg.cifs.mountRoot}/${share}" {
        device = "//${cfg.cifs.server}/${share}";
        fsType = "cifs";
        options =
          cifsBaseOptions
          ++ lib.optional cfg.cifs.ro "ro"
          ++ lib.optional (credPath != null) "credentials=${credPath}";
      }
    ) cfg.cifs.shares
  );
in
{
  options.paxos.plugins.mounts = {
    enable = lib.mkEnableOption "SPEC-driven NFS/CIFS mounts";

    nfs = {
      server = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = ep.hosts.storage;
      };
      fsType = lib.mkOption {
        type = lib.types.str;
        default = "nfs";
        description = "nfs or nfs4";
      };
      exports = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              dest = lib.mkOption { type = lib.types.str; };
              src = lib.mkOption { type = lib.types.str; };
              ro = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
              idleTimeout = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
              };
              server = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              fsType = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            };
          }
        );
        default = [ ];
        description = "NFS exports: dest, src, and optional ro/server/fsType/idleTimeout.";
      };
    };

    cifs = {
      server = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = ep.hosts.storage;
      };
      shares = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      mountRoot = lib.mkOption {
        type = lib.types.str;
        default = "/mnt";
      };
      ro = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Mount every share read-only.";
      };
      uid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "CIFS mount uid";
      };
      gid = lib.mkOption {
        type = lib.types.int;
        default = 100;
        description = "CIFS mount gid";
      };
      credentialsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Decrypted credentials path; default /run/agenix/samba-creds when secretFile set";
      };
      secretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Age-encrypted samba creds in the SPEC vault";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.nfs.exports == [ ]
          || cfg.nfs.server != null
          || lib.all (m: m ? server && m.server != null) cfg.nfs.exports;
        message = "paxos.plugins.mounts.nfs.server required when exports omit server";
      }
      {
        assertion = cfg.cifs.shares == [ ] || cfg.cifs.server != null;
        message = "paxos.plugins.mounts.cifs.server required when shares is non-empty";
      }
      {
        assertion =
          cfg.cifs.shares == [ ] || cfg.cifs.secretFile != null || cfg.cifs.credentialsFile != null;
        message = "paxos.plugins.mounts.cifs needs secretFile or credentialsFile when shares is non-empty";
      }
    ];

    boot.supportedFilesystems =
      lib.optionals (cfg.nfs.exports != [ ]) [
        "nfs"
        "nfs4"
      ]
      ++ lib.optional (cfg.cifs.shares != [ ]) "cifs";

    environment.systemPackages =
      lib.optionals (cfg.nfs.exports != [ ]) [ pkgs.nfs-utils ]
      ++ lib.optionals (cfg.cifs.shares != [ ]) [
        pkgs.cifs-utils
        pkgs.samba
      ];

    age.secrets = lib.mkIf (cfg.cifs.secretFile != null) {
      samba-creds = {
        file = cfg.cifs.secretFile;
        mode = "0400";
      };
    };

    fileSystems = nfsFileSystems // cifsFileSystems;

    systemd.services = nfsRetry.services;
    systemd.timers = nfsRetry.timers;
  };
}
