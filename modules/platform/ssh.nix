


{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.paxos.plugins.ssh;
  persistKeys = "${config.paxos.persist.sshDir}/authorized_keys";
  extraFile = builtins.getEnv "PAXOS_EDGE_SSH_AUTHORIZED_KEYS_FILE";
  operatorKeys =
    if extraFile == "" then
      [ ]
    else
      lib.filter (k: k != "" && !(lib.hasPrefix "#" k)) (
        lib.splitString "\n" (builtins.readFile extraFile)
      );
in
{
  options.paxos.plugins.ssh = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "OpenSSH server (default on)";
    };

    allowFrom = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Source addresses allowed to open SSH. Null leaves port 22 unrestricted.";
    };


    allowTcpForwarding = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow local TCP forwarding, including ProxyJump. Remote forwarding stays off.";
    };

    extraAllowUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra sshd AllowUsers entries. Each is a user or user@host.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.operator.openssh.authorizedKeys.keys = config.paxos.ssh.authorizedKeys ++ operatorKeys;

    networking.firewall.extraInputRules = lib.mkIf (cfg.allowFrom != null) ''
      ip saddr { ${lib.concatStringsSep ", " cfg.allowFrom} } tcp dport 22 accept comment "ssh allowFrom"
    '';

    environment.etc."ssh/paxos-user-ca.pub".text = ''
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLECAKEYPLACEHOLDER paxos-user-ca
    '';
    users.users.operator.openssh.authorizedPrincipals = [ "operator" ];

    services.openssh = {
      enable = true;
      openFirewall = cfg.allowFrom == null;
      authorizedKeysFiles = [ persistKeys ];


      extraConfig = ''
        Match User ops
          AuthorizedKeysFile /etc/ssh/authorized_keys.d/ops
      '';


      hostKeys = [
        {
          path = "${config.paxos.persist.sshDir}/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
      settings = {
        AllowUsers = [
          "operator"
          "ops@192.0.2.10"
        ]
        ++ cfg.extraAllowUsers;
        PasswordAuthentication = false;
        PubkeyAuthentication = true;
        PermitRootLogin = "no";
        KbdInteractiveAuthentication = false;
        MaxAuthTries = 3;
        LoginGraceTime = 30;
        ClientAliveInterval = 300;
        ClientAliveCountMax = 2;
        X11Forwarding = false;
        AllowTcpForwarding = if cfg.allowTcpForwarding then "local" else "no";
        AllowAgentForwarding = false;
        TrustedUserCAKeys = "/etc/ssh/paxos-user-ca.pub";
        KexAlgorithms = [
          "sntrup761x25519-sha512@openssh.com"
          "curve25519-sha256"
          "curve25519-sha256@libssh.org"
          "diffie-hellman-group16-sha512"
          "diffie-hellman-group18-sha512"
        ];
        Ciphers = [
          "chacha20-poly1305@openssh.com"
          "aes256-gcm@openssh.com"
          "aes128-gcm@openssh.com"
        ];
        Macs = [
          "hmac-sha2-512-etm@openssh.com"
          "hmac-sha2-256-etm@openssh.com"
          "umac-128-etm@openssh.com"
        ];
      };
    };

    programs.ssh.extraConfig = ''
      Host *
        HashKnownHosts yes
        StrictHostKeyChecking ask
        VerifyHostKeyDNS yes
        KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
        Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
        MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
    '';

    systemd.tmpfiles.rules = [


      "d ${config.paxos.persist.sshDir} 0755 root root -"
    ];

    systemd.services.paxos-edge-persist-ssh-keys = {
      description = "Stage edge operator SSH keys onto persist";
      wantedBy = [ "sshd.service" ];
      before = [ "sshd.service" ];
      after = [ "sshd-keygen.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "paxos-edge-persist-ssh-keys" ''
          set -euo pipefail
          dest="${persistKeys}"
          dir="$(dirname "$dest")"
          mkdir -p "$dir"
          chmod 755 "$dir"
          src=/etc/ssh/authorized_keys.d/operator
          if [ ! -s "$src" ]; then
            exit 0
          fi
          if [ -f "$dest" ] && [ "$(cksum < "$src")" = "$(cksum < "$dest")" ]; then
            exit 0
          fi
          tmp="$(mktemp "$dir/authorized_keys.XXXXXX")"
          cat "$src" > "$tmp"
          chmod 644 "$tmp"
          mv -f "$tmp" "$dest"
        '';
      };
    };

    systemd.services.sshd.serviceConfig = {
      LockPersonality = true;
      ProtectClock = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
        "AF_NETLINK"
        "AF_VSOCK"
      ];
      SystemCallArchitectures = "native";
    };

    systemd.services.sshd-keygen.serviceConfig = {
      ProtectSystem = "strict";
      ReadWritePaths = [
        "/etc/ssh"
        "${config.paxos.persist.sshDir}"
      ];
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectHostname = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      CapabilityBoundingSet = [
        "CAP_CHOWN"
        "CAP_FOWNER"
        "CAP_DAC_OVERRIDE"
      ];
      SystemCallArchitectures = "native";
      NoNewPrivileges = true;
      MemoryDenyWriteExecute = true;
    };
  };
}
