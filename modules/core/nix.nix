{ lib, ... }:

{
  config = {
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      sandbox = true;
      trusted-users = lib.mkForce [
        "root"
        "ops"
      ];

      accept-flake-config = false;
      flake-registry = "";

      substituters = lib.mkBefore [ "https://cache.example.com" ];
      fallback = true;
    };

  };
}
