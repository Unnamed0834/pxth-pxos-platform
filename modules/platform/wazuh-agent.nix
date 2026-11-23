{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.paxos.wazuhAgent;
  ids = import ../runtime/ids.nix;
  images = import ../runtime/images.nix;
  agentRoot = "/persist/wazuh-agent";

  agentDeb = pkgs.fetchurl {
    url = images.wazuh.agentDebUrl;
    sha256 = images.wazuh.agentDebHash;
  };

  agentTree =
    pkgs.runCommand "wazuh-agent-tree"
      {
        nativeBuildInputs = [
          pkgs.dpkg
          pkgs.patchelf
        ];
      }
      ''
        mkdir -p $out
        dpkg-deb -x ${agentDeb} $out
        mv $out/var/ossec $out/tree
        rm -rf $out/var
        for b in $out/tree/bin/* $out/tree/lib/*.so*; do
          if [ "$(head -c 4 "$b")" = "$(printf '\177ELF')" ]; then
            patchelf --set-interpreter ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 \
              --force-rpath --add-rpath ${pkgs.glibc}/lib \
              --add-rpath ${pkgs.systemd}/lib "$b" 2>/dev/null || true
          fi
        done
      '';
in
{
  options.paxos.wazuhAgent = {
    enable = lib.mkEnableOption "Wazuh 5.0 agent with token enrollment";

    managerAddress = lib.mkOption {
      type = lib.types.str;
      default = "wazuh.example.com";
      description = "Manager endpoint for enrollment (port 1517 and the /wazuh-manager prefix are agent defaults).";
    };

    rootcheckIgnores = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/var/lib/some-job-sandbox" ];
      description = ''
        Paths the rootcheck sweep skips, emitted as <ignore> entries in the
        rootcheck block. Paths must not contain the pipe character (sed delimiter).
      '';
    };

    confTemplate = lib.mkOption {
      type = lib.types.path;
      default = pkgs.writeText "ossec.conf.in" ''
        <ossec_config>
          <agent>
            <manager>
              <endpoint>@MANAGER@</endpoint>
            </manager>
            <config-profile>linux</config-profile>
          </agent>
          <client_buffer>
            <disabled>no</disabled>
            <queue_size>5000</queue_size>
            <events_per_second>500</events_per_second>
          </client_buffer>
          <wodle name="syscollector">
            <disabled>no</disabled>
            <interval>12h</interval>
            <scan_on_start>yes</scan_on_start>
            <hardware>yes</hardware>
            <os>yes</os>
            <network>yes</network>
            <packages>yes</packages>
            <ports all="no">yes</ports>
            <processes>yes</processes>
            <synchronization>
              <enabled>yes</enabled>
              <interval>5m</interval>
              <integrity_interval>24h</integrity_interval>
            </synchronization>
          </wodle>
          <localfile>
            <location>journald</location>
            <log_format>journald</log_format>
            <filter field="SYSLOG_IDENTIFIER">^(sshd|sshd-session|sudo|su)$</filter>
          </localfile>
          <localfile>
            <location>journald</location>
            <log_format>journald</log_format>
            <filter field="SYSLOG_IDENTIFIER">^site-restic$</filter>
          </localfile>
          <localfile>
            <location>journald</location>
            <log_format>journald</log_format>
            <filter field="SYSLOG_IDENTIFIER">^paxos-alert$</filter>
          </localfile>
          <localfile>
            <log_format>audit</log_format>
            <location>/var/log/audit/audit.log</location>
            <only-future-events>yes</only-future-events>
          </localfile>
          <syscheck>
            <disabled>no</disabled>
            <frequency>43200</frequency>
            <directories check_all="yes">/etc</directories>
            <ignore>/etc/mtab</ignore>
            <ignore>/etc/hosts</ignore>
            <ignore>/etc/hostname</ignore>
            <synchronization>
              <enabled>yes</enabled>
              <interval>5m</interval>
              <integrity_interval>24h</integrity_interval>
            </synchronization>
          </syscheck>
          <rootcheck>
            <disabled>no</disabled>
            @ROOTCHECK_IGNORES@
          </rootcheck>
        </ossec_config>
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.age.identityPaths != [ ];
        message = "paxos.wazuhAgent needs an agenix identity (agenix-keys.sh gen+plant)";
      }
    ];

    age.secrets.wazuh-enroll = {
      file = ../../examples/secrets/node/enroll-password.env;
      mode = "0400";
    };

    users.users.wazuh = {
      isSystemUser = true;
      group = "wazuh";
      uid = ids.wazuh.uid;
      extraGroups = [ "systemd-journal" ];
    };
    users.groups.wazuh.gid = ids.wazuh.gid;

    systemd.tmpfiles.rules = [
      "d ${agentRoot} 0750 root wazuh -"
      "L+ /var/ossec - - - - ${agentRoot}"
    ];

    systemd.services.wazuh-agent = {
      wantedBy = [ "multi-user.target" ];
      wants = [
        "agenix-decrypt.service"
        "network-online.target"
      ];
      after = [
        "agenix-decrypt.service"
        "network-online.target"
      ];
      path = [
        pkgs.coreutils
        pkgs.gawk
        pkgs.procps
        pkgs.gnused
        pkgs.gnugrep
        pkgs.findutils
        pkgs.sqlite
      ];
      serviceConfig = {
        Type = "forking";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = 120;
        TimeoutStopSec = 120;
        KillMode = "control-group";
        ExecStartPre = pkgs.writeShellScript "wazuh-agent-seed" ''
          set -euo pipefail
          marker=${agentRoot}/.wazuh-agent-package
          keep=/run/wazuh-agent-keep
          if [ ! -e ${agentRoot}/VERSION.json ] || \
             [ "$(cat "$marker" 2>/dev/null || true)" != "${agentTree}" ]; then
            rm -rf "$keep"
            if [ -s ${agentRoot}/etc/reenroll.secret ]; then
              mkdir -p "$keep/certs"
              install -m 0600 ${agentRoot}/etc/client.keys "$keep/client.keys"
              install -m 0600 ${agentRoot}/etc/reenroll.secret "$keep/reenroll.secret"
              if [ -f ${agentRoot}/etc/certs/root-ca.pem ]; then
                install -m 0644 ${agentRoot}/etc/certs/root-ca.pem "$keep/certs/root-ca.pem"
              fi
            fi
            cp -a --remove-destination ${agentTree}/tree/. ${agentRoot}/
            if [ -d "$keep" ]; then
              install -m 0660 -o root -g wazuh "$keep/client.keys" ${agentRoot}/etc/client.keys
              install -m 0600 -o root -g root "$keep/reenroll.secret" ${agentRoot}/etc/reenroll.secret
              if [ -f "$keep/certs/root-ca.pem" ]; then
                install -d -m 0750 -o root -g wazuh ${agentRoot}/etc/certs
                install -m 0644 "$keep/certs/root-ca.pem" ${agentRoot}/etc/certs/root-ca.pem
              fi
              rm -rf "$keep"
            fi
            printf '%s\n' "${agentTree}" > "$marker"
            chmod 0640 "$marker"
            chown root:wazuh "$marker"
          fi
          install -d -m 0770 -o wazuh -g wazuh ${agentRoot}/etc ${agentRoot}/logs
          install -d -m 0750 -o wazuh -g wazuh ${agentRoot}/logs/wazuh ${agentRoot}/queue/rids
          install -d -m 0770 -o root -g wazuh ${agentRoot}/etc/shared
          install -d -m 1770 -o root -g wazuh ${agentRoot}/tmp
          install -d -m 0750 -o root -g wazuh ${agentRoot}/queue ${agentRoot}/var
          install -d -m 0770 -o wazuh -g wazuh ${agentRoot}/queue/sockets ${agentRoot}/var/agent
          sed "s|/var/ossec|${agentRoot}|g" \
            ${agentTree}/tree/packages_files/agent_installation_scripts/restore-permissions.sh | ${pkgs.bash}/bin/bash
          chown -R wazuh:wazuh ${agentRoot}/logs ${agentRoot}/queue ${agentRoot}/var/agent
          chown wazuh:wazuh ${agentRoot}/tmp
          drop_queue_db() {
            rm -f "$1" "$1-journal" "$1-wal" "$1-shm"
          }
          stale_sync_db() {
            local db=$1 table=$2 col
            [ -f "$db" ] || return 1
            col=$(sqlite3 "$db" "SELECT name FROM pragma_table_info('$table') WHERE name='sync';" 2>/dev/null || printf stale)
            [ "$col" != sync ]
          }
          if stale_sync_db ${agentRoot}/queue/syscollector/db/local.db dbsync_packages; then
            drop_queue_db ${agentRoot}/queue/syscollector/db/local.db
            drop_queue_db ${agentRoot}/queue/syscollector/db/syscollector_sync.db
            drop_queue_db ${agentRoot}/queue/syscollector/db/syscollector_vd_sync.db
          fi
          if stale_sync_db ${agentRoot}/queue/fim/db/fim.db file_entry; then
            drop_queue_db ${agentRoot}/queue/fim/db/fim.db
            drop_queue_db ${agentRoot}/queue/fim/db/fim_sync.db
          fi
          token=$(tr -d '\n\r' < /run/agenix/wazuh-enroll)
          test -n "$token"
          sed -e "s|@MANAGER@|${cfg.managerAddress}|g" \
              -e "s|@ROOTCHECK_IGNORES@|${
                lib.concatMapStrings (p: "<ignore>${p}</ignore>") cfg.rootcheckIgnores
              }|g" \
              ${cfg.confTemplate} > ${agentRoot}/etc/ossec.conf
          chmod 0640 ${agentRoot}/etc/ossec.conf
          chown root:wazuh ${agentRoot}/etc/ossec.conf
          if [ ! -s ${agentRoot}/etc/reenroll.secret ]; then
            rm -f ${agentRoot}/etc/client.keys ${agentRoot}/etc/authd.pass
            printf '%s' "$token" > ${agentRoot}/etc/enrollment_token
            chmod 0600 ${agentRoot}/etc/enrollment_token
            chown root:root ${agentRoot}/etc/enrollment_token
          fi
        '';
        ExecStart = "${agentRoot}/bin/wazuh-control start";
        ExecStop = "${agentRoot}/bin/wazuh-control stop";
        ExecReload = "${agentRoot}/bin/wazuh-control reload";
      };
    };
  };
}
