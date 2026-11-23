
{
  lib,
  pkgs,
}:
{
  podman,
  container,
  discover,
  attempts,
  interval,
  message,
}:
let
  envFile = discover.envFile or null;
  user = discover.user or null;
  database = discover.database or null;
  fromEnv = envFile != null;
  named = user != null || database != null;
in
if fromEnv && named then
  throw "postgres-wait: discover carries an env file and a user"
else if !fromEnv && (user == null || database == null) then
  throw "postgres-wait: discover needs user and database"
else
  let
    role = if fromEnv then ''"$user"'' else lib.escapeShellArg user;
    db = if fromEnv then ''"$database"'' else lib.escapeShellArg database;
    lookup =
      if fromEnv then
        ''
          user=$(${pkgs.gnugrep}/bin/grep '^POSTGRES_USER=' ${lib.escapeShellArg envFile} | ${pkgs.coreutils}/bin/cut -d= -f2-)
          database=$(${pkgs.gnugrep}/bin/grep '^POSTGRES_DB=' ${lib.escapeShellArg envFile} | ${pkgs.coreutils}/bin/cut -d= -f2-)
        ''
      else
        "";
    ready = "${podman} exec ${lib.escapeShellArg container} pg_isready -U ${role} -d ${db}";
  in
  ''
    set -euo pipefail
    ${lookup}for _ in $(${pkgs.coreutils}/bin/seq 1 ${toString attempts}); do
      if ${ready}; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep ${toString interval}
    done
    echo ${lib.escapeShellArg message} >&2
    exit 1
  ''
