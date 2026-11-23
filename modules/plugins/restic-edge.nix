
{
  config,
  lib,
}:
lib.optional config.paxos.plugins.restic.enable "restic-bootstrap.service"
