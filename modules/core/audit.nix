{
  lib,
  config,
  pkgs,
  ...
}:

let

  ephemeralRules = lib.optionals config.paxos.ephemeral.enable [
    "-w ${config.paxos.persist.sshDir}/ -p wa -k persist_ssh_tamper"
    "-w ${config.paxos.persist.secretsDir}/ -p wa -k persist_secrets_tamper"
  ];
in
{
  config = {
    security.audit = {
      enable = lib.mkDefault true;


      failureMode = "printk";
      rules = [

        "-w /etc/passwd -p wa -k identity_changes"
        "-w /etc/shadow -p wa -k identity_changes"
        "-w /etc/group -p wa -k identity_changes"
        "-w /etc/gshadow -p wa -k identity_changes"
        "-w /etc/sudoers -p wa -k identity_changes"
        "-w /etc/sudoers.d/ -p wa -k identity_changes"


        "-w /var/lib/paxos/ -p wa -k paxos_config"


        "-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time_change"


        "-w /etc/systemd/network/ -p wa -k network_changes"


        "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k module_tamper"

        "-a always,exit -F arch=b64 -S all -F path=${config.security.wrapperDir}/sudo -F perm=x -F auid>=1000 -F auid!=unset -k privileged-command"
        "-a always,exit -F arch=b64 -S all -F path=${config.security.wrapperDir}/sudoedit -F perm=x -F auid>=1000 -F auid!=unset -k privileged-command"
      ]
      ++ ephemeralRules;
    };

    security.auditd.enable = lib.mkDefault true;


    boot.kernel.sysctl."kernel.audit_backlog_limit" = lib.mkDefault 8192;

    systemd.packages = lib.mkIf config.paxos.ephemeral.enable [
      (pkgs.writeTextDir "etc/systemd/system/auditd.service.d/99-paxos-eyd.conf" ''
        [Unit]
        Before=
        After=
        After=local-fs.target persist.mount
        Before=shutdown.target
      '')
    ];


    systemd.services.auditd.serviceConfig = {
      ProtectHome = true;
      ProtectSystem = "strict";
      LogsDirectory = "audit";
      RuntimeDirectory = "audit";
      ReadWritePaths = [
        "/var/log/audit"
      ]
      ++ lib.optionals config.paxos.ephemeral.enable [
        "/persist/var/log/audit"
      ];
      PrivateTmp = true;
      ProtectKernelModules = true;
      ProtectClock = true;
      ProtectHostname = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [
        "AF_NETLINK"
        "AF_UNIX"
      ];
      SystemCallArchitectures = "native";
      CapabilityBoundingSet = [
        "CAP_AUDIT_CONTROL"
        "CAP_AUDIT_WRITE"
        "CAP_AUDIT_READ"
        "CAP_SETUID"
        "CAP_SETGID"
        "CAP_DAC_OVERRIDE"
        "CAP_DAC_READ_SEARCH"
        "CAP_SYS_NICE"
      ];
    };

    systemd.services.audit-rules-nixos.serviceConfig = {
      ProtectHome = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [
        "AF_NETLINK"
        "AF_UNIX"
      ];
      SystemCallArchitectures = "native";
      CapabilityBoundingSet = [
        "CAP_AUDIT_CONTROL"
      ];
      NoNewPrivileges = true;
      MemoryDenyWriteExecute = true;
    };
  };
}
