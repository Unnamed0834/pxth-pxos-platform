{ config, lib, ... }:

{
  systemd.services.nix-gc.script = lib.mkForce ''
    ${config.nix.package.out}/bin/nix-env \
      --delete-generations +3 \
      --profile /nix/var/nix/profiles/system
    exec ${config.nix.package.out}/bin/nix-collect-garbage ${config.nix.gc.options}
  '';
}
