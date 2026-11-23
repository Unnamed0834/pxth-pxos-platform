
{
  pkgs,
  lib,
  config,
}:
let
  podman = "${pkgs.podman}/bin/podman";
  runners = import ./stack-runner.nix { inherit pkgs lib; };
  resticEdge = import ../plugins/restic-edge.nix { inherit config lib; };
in
{
  inherit podman;
  inherit (runners) make;
  runner = runners.make;

  service =
    {
      name,
      unitName,
      description,
      podName,
      uidOffset,
      uidCount,
      execStart,
      stopNames,
      memory,
      cpuQuota,
      volumes ? [ ],
      remapFrom ? null,
      defaultVolumeOwner ? 1000,
      volumeOwners ? { },
      ports ? [ ],
      extraPodArgs ? [ ],
      preCreate ? [ ],
      postCreate ? [ ],
      extraAfter ? [ ],
      stopTimeout ? 10,
      timeoutStartSec ? "300s",
      timeoutStopSec ? "30s",
    }:
    let
      runner = runners.make {
        inherit
          name
          uidOffset
          uidCount
          volumes
          remapFrom
          defaultVolumeOwner
          volumeOwners
          ;
      };
    in
    lib.mkMerge [
      runner.userConfig
      {
        systemd.services.${unitName} = {
          inherit description;
          wantedBy = [ "multi-user.target" ];

          after = [ "network-online.target" ] ++ runner.after ++ extraAfter ++ resticEdge;
          wants = [ "network-online.target" ] ++ resticEdge;
          inherit (runner) requires;

          serviceConfig = {
            Type = "exec";
            User = runner.user;
            Group = runner.user;
            WorkingDirectory = runner.home;
            Environment = runner.environment;
            Restart = "always";
            RestartSec = "10s";
            TimeoutStartSec = timeoutStartSec;
            TimeoutStopSec = timeoutStopSec;
            MemoryMax = memory;
            CPUQuota = cpuQuota;

            ExecStartPre = [
              "-${podman} pod rm -f ${podName}"
            ]
            ++ runner.migratePre
            ++ preCreate
            ++ [
              (
                "${podman} pod create --name ${podName} ${runner.uidmap}"
                + lib.optionalString (extraPodArgs != [ ]) " ${lib.concatStringsSep " " extraPodArgs}"
                + lib.optionalString (ports != [ ]) " ${lib.concatMapStringsSep " " (p: "-p ${p}") ports}"
              )
            ]
            ++ postCreate;
            ExecStart = execStart;
            ExecStop = "${podman} stop -t ${toString stopTimeout} ${lib.concatStringsSep " " stopNames}";
            ExecStopPost = "-${podman} pod rm -f ${podName}";
          };
        };
      }
    ];
}
