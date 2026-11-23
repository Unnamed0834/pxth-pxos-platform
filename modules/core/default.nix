{ ... }:

{
  imports = [
    ../platform/options.nix
    ./ephemeral.nix
    ./persist-system.nix
    ./persist-optional.nix
    ./hardening.nix
    ./console.nix
    ./locale.nix
    ./audit.nix
    ./users.nix
    ./networking.nix
    ./nix.nix
    ./secrets.nix
  ];
}
