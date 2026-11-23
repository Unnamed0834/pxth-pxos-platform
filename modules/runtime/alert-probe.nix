
{ lib, pkgs }:
{
  name,
  description,
  result,
  fields ? "",
  check,
  after,
  wants ? [ "network-online.target" ],
  path ? [ ],
  hostname ? "${pkgs.inetutils}/bin/hostname -s",
  timerConfig,
}:
let
  suffix = if fields == "" then "" else " ${fields}";
in
{
  service = {
    inherit description after wants;
  }
  // lib.optionalAttrs (path != [ ]) { inherit path; }
  // {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript name ''
        set -euo pipefail
        if ! ${lib.trim check}; then
          ${pkgs.util-linux}/bin/logger -t paxos-alert -p user.err -- \
            "result=${result} host=$(${hostname})${suffix}"
          exit 1
        fi
      '';
    };
  };

  timer = {
    wantedBy = [ "timers.target" ];
    inherit timerConfig;
  };
}
