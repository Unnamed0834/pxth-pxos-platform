{
  pkgs,
  lib,
}:
let
  ids = import ./ids.nix;
  podman = "${pkgs.podman}/bin/podman";
  hostRoot = uidOffset: 100000 + uidOffset - 1;
  volumeNames =
    specs:
    lib.unique (
      lib.filter (n: n != null && n != "") (
        map (
          spec:
          let
            s = toString spec;
          in
          if lib.hasPrefix "/" s then null else lib.head (lib.splitString ":" s)
        ) specs
      )
    );
in
{
  userName = name: "stk-${name}";

  make =
    {
      name,
      uidOffset,
      uidCount,
      volumes ? [ ],

      remapFrom ? null,

      defaultVolumeOwner ? 1000,
      volumeOwners ? { },
    }:
    let
      user = "stk-${name}";
      id = ids.${user} or (throw "stack runner ${user} has no pinned id in modules/runtime/ids.nix");
      home = "/persist/var/lib/stack/${name}";
      runtime = "/run/user/${toString id.uid}";
      names = volumeNames volumes;
      newBase = hostRoot uidOffset;
      oldBase = if remapFrom == null then null else hostRoot remapFrom;

      oldRoot = "/persist/var/lib/containers/home/.local/share/containers/storage/volumes";
      migrate = pkgs.writeShellScript "stk-${name}-volumes" ''
        set -euo pipefail
        cd /
        install -d -o ${user} -g ${user} -m 0700 ${lib.escapeShellArg home}

        install -d -m 1777 /persist/tmp
        moved=0
        imageNeed=
        oldStore=/persist/var/lib/containers/home/.local/share/containers/storage
        ${lib.concatMapStrings (vol: ''
          vol=${lib.escapeShellArg vol}
          runuser -u ${user} -- env \
            HOME=${lib.escapeShellArg home} \
            XDG_RUNTIME_DIR=${lib.escapeShellArg runtime} \
            TMPDIR=/persist/tmp \
            PATH=/run/wrappers/bin:/run/current-system/sw/bin \
            ${podman} volume create "$vol" >/dev/null 2>&1 || true
          new=$(runuser -u ${user} -- env \
            HOME=${lib.escapeShellArg home} \
            XDG_RUNTIME_DIR=${lib.escapeShellArg runtime} \
            TMPDIR=/persist/tmp \
            PATH=/run/wrappers/bin:/run/current-system/sw/bin \
            ${podman} volume inspect "$vol" --format '{{.Mountpoint}}')
          old="${oldRoot}/$vol/_data"
          if [ -d "$old" ] && [ -n "$(ls -A "$old" 2>/dev/null || true)" ]; then
            if [ -z "$(ls -A "$new" 2>/dev/null || true)" ]; then
              if [ -z "$imageNeed" ]; then
                imageNeed=0
                if [ -d "$oldStore/overlay" ]; then
                  imageNeed=$(${pkgs.coreutils}/bin/du -sb "$oldStore/overlay" | ${pkgs.gawk}/bin/awk '{print $1}')
                fi
              fi
              need=$(${pkgs.coreutils}/bin/du -sb "$old" | ${pkgs.gawk}/bin/awk '{print $1}')
              avail=$(${pkgs.coreutils}/bin/df -B1 --output=avail "$new" | ${pkgs.gawk}/bin/awk 'NR==2 {print $1}')

              if [ "$avail" -lt $((need + imageNeed + 1073741824)) ]; then
                oldDev=$(${pkgs.coreutils}/bin/stat -c %d "$old")
                newDev=$(${pkgs.coreutils}/bin/stat -c %d "$new")
                if [ "$oldDev" != "$newDev" ]; then
                  echo "stk-${name}: $vol needs $need bytes and $avail are free" >&2
                  exit 1
                fi
                mkdir -p /persist/var/lib
                printf '%s\t%s\n' "$old" "$new" >> /persist/var/lib/stack-moves
                rmdir "$new"
                mv "$old" "$new"
                moved=1
              else
                cp -a "$old/." "$new/"
              fi
              ${lib.optionalString (remapFrom != null) ''
                ${lib.getExe pkgs.paxos-glue} subuid-walk "$new" ${toString oldBase} ${toString newBase} ${toString uidCount}
              ''}
              chown ${toString newBase}:${toString newBase} "$new"
            fi
          fi
        '') names}

        if [ "$moved" = 1 ]; then
          exec 9>/persist/var/lib/stack-moves.lock
          ${pkgs.util-linux}/bin/flock 9
          rm -rf \
            "$oldStore/overlay" \
            "$oldStore/overlay-layers" \
            "$oldStore/overlay-images" \
            "$oldStore/overlay-containers"
        fi
      '';

      volRepair = pkgs.writeShellScript "stk-${name}-vol-repair" ''
        set -euo pipefail
        cd /
        ${lib.concatMapStrings (
          vol:
          let
            owner = volumeOwners.${vol} or defaultVolumeOwner;
            want = toString (1 + owner);
          in
          ''
            vol=${lib.escapeShellArg vol}
            runuser -u ${user} -- env \
              HOME=${lib.escapeShellArg home} \
              XDG_RUNTIME_DIR=${lib.escapeShellArg runtime} \
              TMPDIR=/persist/tmp \
              PATH=/run/wrappers/bin:/run/current-system/sw/bin \
              ${podman} volume create "$vol" >/dev/null 2>&1 || true
            VOL_DIR=$(runuser -u ${user} -- env \
              HOME=${lib.escapeShellArg home} \
              XDG_RUNTIME_DIR=${lib.escapeShellArg runtime} \
              TMPDIR=/persist/tmp \
              PATH=/run/wrappers/bin:/run/current-system/sw/bin \
              ${podman} volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
            if [ -n "$VOL_DIR" ] && [ -d "$VOL_DIR" ]; then
              runuser -u ${user} -- env \
                HOME=${lib.escapeShellArg home} \
                XDG_RUNTIME_DIR=${lib.escapeShellArg runtime} \
                TMPDIR=/persist/tmp \
                PATH=/run/wrappers/bin:/run/current-system/sw/bin \
                ${podman} unshare sh -c '
                  dir=$1
                  want=$2
                  if [ -z "$(ls -A "$dir" 2>/dev/null || true)" ] || [ "$(stat -c %u "$dir")" != "$want" ]; then
                    chown -R "$want:$want" "$dir"
                    chmod -R u+rwX,go-rwx "$dir"
                  fi
                ' sh "$VOL_DIR" ${want}
            fi
          ''
        ) names}
      '';
    in
    {
      inherit user home runtime;
      inherit (id) uid;

      unshareOf = containerUid: 1 + containerUid;
      uidmap = "--uidmap 0:1:${toString uidCount} --gidmap 0:1:${toString uidCount}";
      environment = [
        "HOME=${home}"
        "XDG_RUNTIME_DIR=${runtime}"

        "TMPDIR=/persist/tmp"
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
      ];
      after = [ "user@${toString id.uid}.service" ];
      requires = [ "user@${toString id.uid}.service" ];

      migratePre = [
        "+${migrate}"
        "${volRepair}"
      ];
      userConfig = {
        users.groups.${user}.gid = id.gid;
        users.users.${user} = {

          isSystemUser = true;
          description = "Rootless runner for ${name}";
          shell = "${pkgs.util-linux}/bin/nologin";
          inherit home;
          createHome = false;
          inherit (id) uid;
          group = user;
          linger = true;
          autoSubUidGidRange = false;
          subUidRanges = [
            {
              startUid = hostRoot uidOffset;
              count = uidCount;
            }
          ];
          subGidRanges = [
            {
              startGid = hostRoot uidOffset;
              count = uidCount;
            }
          ];
        };
        systemd.tmpfiles.rules = [
          "d /persist/var/lib/stack 0755 root root -"
          "d ${home} 0700 ${user} ${user} -"
          "d /persist/tmp 1777 root root -"
        ];
      };
    };
}
