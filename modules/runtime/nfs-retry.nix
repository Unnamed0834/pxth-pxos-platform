{ lib }:
let

  escPath =
    mp:
    let
      stripped =
        if builtins.substring 0 1 mp == "/" then builtins.substring 1 (builtins.stringLength mp) mp else mp;
    in
    builtins.replaceStrings [ "/" ] [ "-" ] stripped;
  unitOf = mp: "${escPath mp}.mount";
  autoOf = mp: "${escPath mp}.automount";
  nameOf = mp: "paxos-nfs-retry-${escPath mp}";
in
{
  mkMountRetry =
    {
      mountPoints,
      timeout ? 90,
      interval ? "5min",
    }:
    let
      timeoutOption = "x-systemd.mount-timeout=${toString timeout}";
    in
    {
      inherit timeoutOption;

      fstabOptions = [
        "nofail"
        timeoutOption
      ];

      services = lib.listToAttrs (
        map (
          mp:
          let
            name = nameOf mp;
          in
          {
            inherit name;
            value = {
              description = "Retry the ${mp} mount and clear its failed state";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              serviceConfig = {
                Type = "oneshot";

                TimeoutStartSec = "${toString (timeout + 30)}s";
              };
              script = ''
                set -uo pipefail
                unit=${lib.escapeShellArg (unitOf mp)}
                automount=${lib.escapeShellArg (autoOf mp)}

                systemctl reset-failed "$unit" || true
                systemctl reset-failed "$automount" || true

                systemctl start "$unit" || true

                exit 0
              '';
            };
          }
        ) mountPoints
      );

      timers = lib.listToAttrs (
        map (
          mp:
          let
            name = nameOf mp;
          in
          {
            inherit name;
            value = {
              description = "Periodically retry the ${mp} mount";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "3min";
                OnUnitActiveSec = interval;
                RandomizedDelaySec = "1min";
                AccuracySec = "30s";
              };
            };
          }
        ) mountPoints
      );
    };

  mkFailedMountRetry =
    { pkgs }:
    {
      service = {
        description = "Retry NFS mounts that failed";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        path = [ pkgs.gawk ];
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          for u in $(systemctl list-units --type=mount --state=failed --no-legend --plain | awk '{print $1}'); do
            what=$(systemctl show "$u" -p What --value 2>/dev/null)
            case "$what" in
              *:*)
                systemctl reset-failed "$u" || true
                systemctl start --no-block "$u" || true
                ;;
            esac
          done
        '';
      };

      timer = {
        description = "Periodically retry NFS mounts that failed";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "2min";
          RandomizedDelaySec = "30s";
          AccuracySec = "30s";
        };
      };
    };
}
