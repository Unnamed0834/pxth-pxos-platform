{
  pkgs,
  lib,
  config,
  ...
}:

let
  resticEdge = import ../plugins/restic-edge.nix { inherit config lib; };
  harden = import ./container-harden.nix;
  runners = import ./stack-runner.nix { inherit pkgs lib; };
  enabledWorkloads = lib.filterAttrs (_: w: w.enable) config.paxos.workloads;
  sortedWorkloads = lib.sort (a: b: a.order < b.order) (lib.attrValues enabledWorkloads);
  workloadsWithOffsets =
    (lib.foldl'
      (
        acc: w:
        let
          offset = if w.uidOffset != null then w.uidOffset else acc.nextOffset;
        in
        {
          nextOffset = offset + w.uidCount;
          result = acc.result ++ [ (w // { computedOffset = offset; }) ];
        }
      )
      {
        nextOffset = 1;
        result = [ ];
      }
      sortedWorkloads
    ).result;
  workloadMap = builtins.listToAttrs (map (w: lib.nameValuePair w.name w) workloadsWithOffsets);
  runnerOf =
    w:
    runners.make {
      inherit (w) name uidCount volumes;
      uidOffset = w.computedOffset;
    };
  parsePort =
    raw:
    let
      s = lib.head (lib.splitString "/" (toString raw));
    in
    lib.toInt s;
  hostPortOf =
    spec:
    let
      parts = lib.splitString ":" (toString spec);
      n = builtins.length parts;
    in
    if n <= 2 then parsePort (builtins.head parts) else parsePort (builtins.elemAt parts (n - 2));
  containerPortOf =
    spec:
    let
      parts = lib.splitString ":" (toString spec);
    in
    parsePort (lib.last parts);
  workloadBindPorts = lib.concatMap (
    w:
    lib.concatMap (p: [
      (hostPortOf p)
      (containerPortOf p)
    ]) (w.ports or [ ])
  ) (lib.attrValues enabledWorkloads);
  lowestHostPort = lib.foldl' lib.min 65535 workloadBindPorts;
  coverPort =
    raw:
    let
      s = lib.removePrefix "https://" (lib.removePrefix "http://" raw);
      parts = lib.splitString ":" s;
    in
    lib.last parts;
in
{
  options.paxos.workloads = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }: {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Workload name";
            };

            enable = lib.mkEnableOption "workload ${name}";

            order = lib.mkOption {
              type = lib.types.int;
              default = 100;
              description = "Sort order for SubUID slice allocation";
            };

            uidOffset = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Explicit SubUID slice offset (default: auto-allocated by order)";
            };

            uidCount = lib.mkOption {
              type = lib.types.int;
              default = 10000;
              description = "Number of SubUIDs allocated to this container";
            };

            volumeUid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Uid inside the container that should own an empty named volume. Null keeps the historical default, container uid 1.";
            };

            image = lib.mkOption {
              type = lib.types.str;
              description = "Container image";
            };

            imageFile = lib.mkOption {

              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Path to a local container image archive (.tar / .tar.gz), loaded by
                `podman load` before the container starts. May be an absolute path
                on the host rather than a repo-relative Nix path, so large image
                archives need not be committed. Fetch and stage the archive
                separately (CI artifact, rsync, or a registry pull).
              '';
            };

            imageDigest = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Cryptographic sha256 digest of container image for supply-chain pinning";
            };

            healthCheck = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional health check command for container";
            };

            shmSize = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Size of /dev/shm for the pod (e.g. '512M', '1G')";
            };

            ports = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Port mappings for the pod";
            };

            volumes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Volume mounts (named volumes or host bind mounts)";
            };

            environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Environment variables";
            };

            devices = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Hardware devices to pass through";
            };

            memory = lib.mkOption {
              type = lib.types.str;
              default = "512M";
              description = "Memory cap for container and systemd cgroup";
            };

            cpu = lib.mkOption {
              type = lib.types.str;
              default = "1.0";
              description = "CPU core quota (e.g. '0.5', '1.0', '2.0')";
            };

            after = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Extra systemd units this service should start after";
            };

            extraArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Extra arguments appended after the capability drop";
            };

            extraPodArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Extra arguments to podman pod create.";
            };

            noNewPrivileges = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Pass no-new-privileges. Turn off when the image execs a binary with file capabilities; that exec returns EPERM while the flag is set.";
            };

            caps = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Capabilities added after the drop. A file capability must be listed here or execve returns EPERM.";
            };

            ownerCaps = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Add CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, and KILL. Images that chown a volume or drop from root need this.";
            };

            allowDangerous = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Allow privileged mode, host network, host pid, or an engine
                socket mount. container-harden.nix rejects those unless this
                is set.
              '';
            };

            command = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Command and arguments passed to the container (appended after the image reference)";
            };

            backends = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = ''
                Published names this workload owns (name → host:port). Empty
                means it is not on Caddy. podman copies enabled entries into
                paxos.cover.backends.
              '';
            };

            coverHold = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Register <name>.service in paxos.cover.resticHold when enabled.";
            };
          };
        }
      )
    );
    default = { };
    description = "Declarative Podman workloads with automatic SubUID slicing and systemd lifecycle";
  };

  config = {
    assertions =
      (lib.mapAttrsToList (_: w: {
        assertion = w.imageFile != null || w.imageDigest != null || lib.hasInfix "@sha256:" w.image;
        message = "paxos.workloads.${w.name} needs imageDigest, imageFile, or a digest-pinned image";
      }) enabledWorkloads)
      ++ lib.concatMap (
        w:
        lib.mapAttrsToList (bname: url: {
          assertion = lib.any (p: lib.hasInfix (coverPort url) (toString p)) w.ports;
          message = "paxos.workloads.${w.name}.backends.${bname} = ${url} but ports is ${toString w.ports}";
        }) w.backends
      ) (lib.attrValues enabledWorkloads);

    paxos.cover.backends = lib.mkMerge (
      lib.mapAttrsToList (_: w: lib.mkIf w.enable w.backends) config.paxos.workloads
    );

    paxos.cover.resticHold = builtins.map (w: "${w.name}.service") (
      lib.attrValues (lib.filterAttrs (_: w: w.enable && w.coverHold) config.paxos.workloads)
    );

    boot.kernel.sysctl = lib.mkIf (workloadBindPorts != [ ] && lowestHostPort < 1024) {
      "net.ipv4.ip_unprivileged_port_start" = lowestHostPort;
    };

    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
    };
    virtualisation.containers.enable = true;

    virtualisation.containers.containersConf.settings = {
      containers = {
        log_driver = "journald";
        pids_limit = 2048;

        userns = "host";
      };
    };

    systemd.user.sockets.podman.wantedBy = [ "sockets.target" ];

    systemd.sockets.podman = {
      description = "Podman API Socket Proxy to containers user";
      socketConfig = {
        ListenStream = "/run/podman/podman.sock";
        SocketMode = "0600";
        SocketUser = lib.mkForce "root";
        SocketGroup = lib.mkForce "root";
      };
    };

    systemd.services = {
      podman = {
        description = "Proxy System Podman Socket to containers user session";
        requires = [
          "podman.socket"
          "user@99999.service"
        ];
        after = [
          "podman.socket"
          "user@99999.service"
        ];
        serviceConfig = {
          Type = lib.mkForce "notify";
          ExecStart = [
            ""
            "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd /run/user/99999/podman/podman.sock"
          ];
          PrivateTmp = true;
        };
      };
    }
    // (lib.mapAttrs' (
      name: w:
      let
        podName = "${name}-pod";
        containerName = name;
        portFlags = lib.concatMapStringsSep " " (p: "-p ${p}") w.ports;
        shmFlag = if w.shmSize != null then "--shm-size ${w.shmSize}" else "";
        volumeFlags = lib.concatMapStringsSep " " (v: "-v ${v}") w.volumes;
        deviceFlags = lib.concatMapStringsSep " " (d: "--device ${d}") w.devices;
        envFlags = lib.concatStringsSep " " (
          lib.mapAttrsToList (k: v: "-e ${toString k}=${lib.escapeShellArg v}") w.environment
        );
        effectiveImage =
          if w.imageFile != null then
            w.image
          else if w.imageDigest != null then
            "${w.image}@${w.imageDigest}"
          else
            w.image;
        healthCheckFlags =
          if w.healthCheck != null then
            "--health-cmd=\"${w.healthCheck}\" --health-interval=30s --health-retries=3"
          else
            "";
        extraFlags = lib.concatStringsSep " " (
          lib.filter (x: x != "") [
            (lib.concatStringsSep " " w.extraArgs)
            healthCheckFlags
          ]
        );
        commandFlags = lib.concatStringsSep " " (map lib.escapeShellArg w.command);
        memPodman = lib.toLower w.memory;

        namedVolumes = builtins.filter (v: !(lib.hasPrefix "/" v)) w.volumes;
        namedVolNames = map (v: builtins.head (lib.splitString ":" v)) namedVolumes;

        volumeOwner = if w.volumeUid == null then 2 else 1 + w.volumeUid;
        runner = runnerOf w;

        volInitScript = pkgs.writeShellScript "${name}-vol-init" ''
          set -euo pipefail
          ${lib.concatMapStringsSep "\n" (vol: ''
            if ! ${pkgs.podman}/bin/podman volume exists "${vol}" 2>/dev/null; then
              ${pkgs.podman}/bin/podman volume create "${vol}" >/dev/null || true
            fi
            VOL_DIR=$(${pkgs.podman}/bin/podman volume inspect "${vol}" --format "{{.Mountpoint}}" 2>/dev/null || true)
            if [ -n "$VOL_DIR" ] && [ -d "$VOL_DIR" ]; then

              ${pkgs.podman}/bin/podman unshare sh -c '
                dir=$1
                want=$2
                if [ -z "$(ls -A "$dir" 2>/dev/null || true)" ] || [ "$(stat -c %u "$dir")" != "$want" ]; then
                  chown -R "$want:$want" "$dir"
                  chmod -R u+rwX,go-rwx "$dir"
                fi
              ' sh "$VOL_DIR" ${toString volumeOwner}
            fi
          '') namedVolNames}
        '';
      in
      lib.nameValuePair name {
        description = "${name} Container Workload";
        wantedBy = [ "multi-user.target" ];

        after = [
          "network-online.target"
        ]
        ++ runner.after
        ++ w.after
        ++ resticEdge;
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
          TimeoutStartSec = "300s";
          TimeoutStopSec = "30s";
          MemoryMax = w.memory;
          CPUQuota = "${toString (builtins.floor (builtins.fromJSON w.cpu * 100))}%";

          ExecStartPre = [
            "-${pkgs.podman}/bin/podman pod rm -f ${podName}"
          ]
          ++ runner.migratePre

          ++ lib.optional (w.imageFile != null) "${pkgs.podman}/bin/podman load -i ${w.imageFile}"
          ++ lib.optional (namedVolNames != [ ]) "${volInitScript}"
          ++ [
            (
              "${pkgs.podman}/bin/podman pod create --name ${podName} ${runner.uidmap} ${portFlags} ${shmFlag}"
              + lib.optionalString (w.extraPodArgs != [ ]) " ${lib.concatStringsSep " " w.extraPodArgs}"
            )
          ];
          ExecStart = harden.run {
            podman = "${pkgs.podman}/bin/podman";
            replace = true;
            name = containerName;
            pod = podName;
            inherit (w)
              noNewPrivileges
              caps
              ownerCaps
              allowDangerous
              ;
            args = lib.concatStringsSep " " (
              lib.filter (s: s != "") [
                "--cpus ${w.cpu}"
                "--memory ${memPodman}"
                deviceFlags
                envFlags
                volumeFlags
                extraFlags
              ]
            );
            image = effectiveImage;
            command = commandFlags;
          };
          ExecStop = "${pkgs.podman}/bin/podman stop -t 10 ${containerName}";
          ExecStopPost = "-${pkgs.podman}/bin/podman pod rm -f ${podName}";
        };
      }
    ) workloadMap);

    systemd.tmpfiles.rules = [
      "d ${config.paxos.persist.containersDir} 0755 containers containers -"
      "d ${config.paxos.persist.containersDir}/home 0700 containers containers -"
      "L+ /var/lib/containers - - - - ${config.paxos.persist.containersDir}"
    ]
    ++ lib.concatMap (w: (runnerOf w).userConfig.systemd.tmpfiles.rules) (lib.attrValues workloadMap);

    users.groups = {
      containers.gid = 99999;
    }
    // lib.foldl' (
      acc: w:
      let
        r = runnerOf w;
      in
      acc // r.userConfig.users.groups
    ) { } (lib.attrValues workloadMap);
    users.users = {
      containers = {
        isNormalUser = true;
        description = "Dedicated Rootless Container User";
        shell = "${pkgs.util-linux}/bin/nologin";
        home = "/var/lib/containers/home";
        createHome = false;
        uid = 99999;
        group = "containers";
        linger = true;
        autoSubUidGidRange = false;

        subUidRanges = [ ];
        subGidRanges = [ ];
      };
    }
    // lib.foldl' (
      acc: w:
      let
        r = runnerOf w;
      in
      acc // r.userConfig.users.users
    ) { } (lib.attrValues workloadMap);
  };
}
