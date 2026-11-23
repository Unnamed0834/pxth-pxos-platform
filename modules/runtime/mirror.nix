
{
  lib,
  pkgs,
}:
let
  harden = import ./service-harden.nix { inherit lib; };
in
rec {
  proxyEnv =
    port:
    let
      url = "http://127.0.0.1:${toString port}";
    in
    {
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      HTTP_PROXY = url;
      HTTPS_PROXY = url;
      http_proxy = url;
      https_proxy = url;
    };

  waitProxy =
    {
      name,
      port ? 8888,
    }:
    ''
      ready=0
      n=0
      while [[ $n -lt 60 ]]; do
        if echo >/dev/tcp/127.0.0.1/${toString port}; then
          ready=1
          break
        fi
        n=$((n + 1))
        sleep 2
      done
      if [[ $ready != 1 ]]; then
        echo "${name}: gluetun proxy is not listening" >&2
        exit 1
      fi
    '';

  script =
    {
      name,
      port ? 8888,
      body,
    }:
    pkgs.writeShellScript name (
      ''
        set -uo pipefail
        fail=0
        ${waitProxy { inherit name port; }}
        step() {
          sname=$1
          shift
          echo "${name}: $sname"
          if "$@"; then
            echo "${name}: ok $sname"
          else
            echo "${name}: failed $sname" >&2
            fail=1
          fi
        }
      ''
      + body
      + ''
        exit "$fail"
      ''
    );

  service =
    job:
    let
      inherit (job)
        description
        path
        writable
        name
        body
        ;
      port = job.port or 8888;
      requires = job.requires or [ ];
    in
    {
      inherit description path;
      after = [ "network-online.target" ] ++ job.after;
      wants = [ "network-online.target" ] ++ job.wants;
      environment = proxyEnv port // (job.environment or { });
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "infinity";
        Nice = 10;
        ExecStart =
          job.exec or (script {
            inherit name port body;
          });
      }
      // lib.optionalAttrs (job ? memoryMax) { MemoryMax = job.memoryMax; }
      // lib.optionalAttrs (job ? stateDirectory) { StateDirectory = job.stateDirectory; }
      // harden.sandbox {
        umask = job.umask or "0022";
        inherit writable;
      };
    }
    // lib.optionalAttrs (requires != [ ]) { inherit requires; }
    // lib.optionalAttrs (job ? requiresMountsFor) {
      unitConfig.RequiresMountsFor = job.requiresMountsFor;
    };

  timer = job: {
    description = job.timerDescription;
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = job.onCalendar;
      Persistent = job.persistent or false;
      RandomizedDelaySec = job.randomizedDelaySec or "20min";
    };
  };

  units = jobs: {
    systemd.services = lib.listToAttrs (
      map (job: {
        inherit (job) name;
        value = service job;
      }) jobs
    );
    systemd.timers = lib.listToAttrs (
      map (job: {
        inherit (job) name;
        value = timer job;
      }) jobs
    );
  };
}
