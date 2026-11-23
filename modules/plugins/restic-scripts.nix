{
  lib,
  pkgs,
  config,
  backupStopShell,
  holdUnitsShell,
  stampPath,
}:
let
  cfg = config.paxos.plugins.restic;
  pgPackage = config.services.postgresql.package;
  dumpDir = cfg.postgres.dumpDir;
  pgDbs = cfg.postgres.databases;

  quiesce = pkgs.writeShellScript "site-restic-quiesce" ''
    set -euo pipefail
    mkdir -p /run/site-restic
    rm -f /run/site-restic/skip
    units=(${backupStopShell})
    [ "''${#units[@]}" -eq 0 ] && exit 0
    echo "site-restic: stopping ''${units[*]} for consistent backup"
    set +e
    out=$(systemctl stop "''${units[@]}" 2>&1)
    status=$?
    set -e
    printf '%s\n' "$out"
    if [ "$status" -eq 0 ]; then
      exit 0
    fi
    case "$out" in
      *canceled*)
        : >/run/site-restic/skip
        echo "site-restic: stop canceled; this backup will be skipped"
        exit 0
        ;;
    esac
    exit "$status"
  '';

  unquiesce = pkgs.writeShellScript "site-restic-unquiesce" ''
    set -euo pipefail
    units=(${holdUnitsShell})
    [ "''${#units[@]}" -eq 0 ] && exit 0
    echo "site-restic: starting ''${units[*]} after backup"

    set +e
    out=$(systemctl start --no-block "''${units[@]}" 2>&1)
    status=$?
    set -e
    printf '%s\n' "$out"
    rm -f /run/site-restic/skip
    if [ "$status" -ne 0 ]; then
      case "$out" in
        *canceled*)
          echo "site-restic: start canceled; the switch is restarting the writers"
          exit 0
          ;;
      esac
      echo "site-restic: hold units did not restart after backup" >&2
      systemctl start site-restic-alert.service || true
      exit "$status"
    fi
    sleep 3
    bad=0
    for unit in "''${units[@]}"; do
      state=$(systemctl show -p ActiveState --value "$unit")
      if [ "$state" = failed ]; then
        echo "site-restic: $unit is failed" >&2
        bad=1
      fi
    done
    if [ "$bad" -ne 0 ]; then
      systemctl start site-restic-alert.service || true
      exit 1
    fi
  '';
  resticCheck = pkgs.writeShellScript "site-restic-check" ''
    set -euo pipefail
    export HOME=/var/lib/restic
    export XDG_CACHE_HOME=/var/lib/restic/cache
    mkdir -p /var/lib/restic/cache
    repo=${lib.escapeShellArg cfg.mountPoint}

    if [ ! -f "$repo/config" ]; then
      echo "site-restic: no repository yet; skip check"
      exit 0
    fi

    ${pkgs.restic}/bin/restic --retry-lock 30m check \
      --repo "$repo" \
      --password-file ${lib.escapeShellArg cfg.passwordFile}
  '';
  resticAge = pkgs.writeShellScript "site-restic-age" ''
    set -euo pipefail
    export HOME=/var/lib/restic
    export XDG_CACHE_HOME=/var/lib/restic/cache
    mkdir -p /var/lib/restic/cache
    repo=${lib.escapeShellArg cfg.mountPoint}
    if [ ! -f "$repo/config" ]; then
      echo "site-restic: no repository yet; skip age"
      exit 0
    fi

    when=$(${pkgs.restic}/bin/restic --retry-lock 30m snapshots --latest 1 --json \
      --repo "$repo" \
      --password-file ${lib.escapeShellArg cfg.passwordFile} \
      | ${pkgs.jq}/bin/jq -r '[.[].time] | max // empty')
    if [ -z "$when" ]; then
      echo "site-restic: no snapshot yet; skip age"
      exit 0
    fi
    now=$(date +%s)
    snap=$(date -d "$when" +%s)
    age_h=$(((now - snap) / 3600))
    if [ "$age_h" -gt ${toString cfg.maxSnapshotAgeHours} ]; then
      ${pkgs.util-linux}/bin/logger -t paxos-alert -p user.err -- \
        "result=stale host=$(${pkgs.inetutils}/bin/hostname -s) age=''${age_h}h snapshot=$when"
      exit 1
    fi
  '';
  resticDrill = pkgs.writeShellScript "site-restic-drill" ''
    set -euo pipefail
    export HOME=/var/lib/restic
    export XDG_CACHE_HOME=/var/lib/restic/cache
    mkdir -p /var/lib/restic/cache
    repo=${lib.escapeShellArg cfg.mountPoint}
    stage=$(mktemp -d /persist/restore-drill.XXXXXX)
    trap 'rm -rf "$stage"' EXIT
    fail() {
      ${pkgs.util-linux}/bin/logger -t paxos-alert -p user.err -- \
        "result=drill-fail host=$(${pkgs.inetutils}/bin/hostname -s) $1"
      exit 1
    }
    if [ ! -f "$repo/config" ]; then
      echo "site-restic: no repository yet; skip drill"
      exit 0
    fi
    if ! ${pkgs.restic}/bin/restic --retry-lock 30m restore latest \
      --repo "$repo" \
      --password-file ${lib.escapeShellArg cfg.passwordFile} \
      --target "$stage" \
      --include ${lib.escapeShellArg stampPath}
    then
      fail "restore"
    fi
    stamp="$stage${stampPath}"

    if [ ! -s "$stamp" ]; then
      echo "site-restic: latest snapshot has no stamp yet; skip drill"
      exit 0
    fi
    ${pkgs.util-linux}/bin/logger -t paxos-alert -p user.notice -- \
      "result=drill-ok host=$(${pkgs.inetutils}/bin/hostname -s) stamp=$(tr -d '\n' < "$stamp")"
  '';

  resticBin = pkgs.writeShellScriptBin "restic" ''
    set -euo pipefail
    if [ -f /run/site-restic/skip ]; then
      if [ "''${1:-}" = backup ]; then
        echo "site-restic: switch canceled the writer stop; backup skipped"
      fi
      exit 0
    fi

    exec ${pkgs.restic}/bin/restic --retry-lock 30m "$@"
  '';
  stampScript = pkgs.writeShellScript "paxos-restic-stamp" ''
    set -euo pipefail
    install -d -m 0755 /persist/var/lib
    printf '%s %s\n' "$(${pkgs.inetutils}/bin/hostname -s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > ${stampPath}
  '';

  pgDumpScript = pkgs.writeShellScript "site-restic-pg-dump" ''
    set -euo pipefail
    if [ -f /run/site-restic/skip ]; then
      echo "site-restic: backup skipped; not dumping"
      exit 0
    fi
    dumpdir=${lib.escapeShellArg dumpDir}
    mkdir -p "$dumpdir"

    chown postgres:postgres "$dumpdir"
    chmod 0750 "$dumpdir"
    ${lib.concatMapStringsSep "\n" (db: ''
      echo "site-restic: pg_dump ${db}"

      ${pkgs.util-linux}/bin/runuser -u postgres -- \
        ${pgPackage}/bin/pg_dump --format=plain --encoding=UTF8 \
        --file="$dumpdir/${db}.sql" ${lib.escapeShellArg db}

      chown postgres:postgres "$dumpdir/${db}.sql"
      chmod 0640 "$dumpdir/${db}.sql"
    '') pgDbs}
  '';

  pgImportScript = pkgs.writeShellScript "site-restic-pg-import" ''
    set -euo pipefail
    dumpdir=${lib.escapeShellArg dumpDir}
    ${lib.concatMapStringsSep "\n" (db: ''
      dump="$dumpdir/${db}.sql"
      if [ ! -s "$dump" ]; then
        echo "site-restic: no dump for ${db}; skip import"
      else

        chown postgres:postgres "$dump"
        chmod 0640 "$dump"
        if ! ${pkgs.util-linux}/bin/runuser -u postgres -- \
            ${pgPackage}/bin/psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" \
            | grep -q 1; then
          echo "site-restic: creating database ${db}"
          ${pkgs.util-linux}/bin/runuser -u postgres -- \
            ${pgPackage}/bin/createdb ${lib.escapeShellArg db}
        fi
        tables=$(${pkgs.util-linux}/bin/runuser -u postgres -- \
          ${pgPackage}/bin/psql -d ${lib.escapeShellArg db} -tAc \
          "SELECT count(*) FROM pg_tables WHERE schemaname='public'")
        if [ "''${tables:-0}" -gt 0 ]; then
          echo "site-restic: ${db} already has ''${tables} tables; skip import"
        else
          echo "site-restic: importing $dump into ${db}"
          ${pkgs.util-linux}/bin/runuser -u postgres -- \
            ${pgPackage}/bin/psql -v ON_ERROR_STOP=1 \
            -d ${lib.escapeShellArg db} -f "$dump"
          echo "site-restic: import ${db} done"
        fi
      fi
    '') pgDbs}
  '';

  alert = pkgs.writeShellScript "site-restic-alert" ''
    ${pkgs.util-linux}/bin/logger -t site-restic -p user.err -- \
      "backup, restart, or repo check failed"
  '';
in
{
  inherit
    quiesce
    unquiesce
    resticCheck
    resticAge
    resticDrill
    resticBin
    stampScript
    pgDumpScript
    pgImportScript
    alert
    ;
}
