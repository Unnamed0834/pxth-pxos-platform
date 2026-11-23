{
  modulesPath,
  lib,
  pkgs,
  ...
}:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExamplePlaceholderKeyForPublicRelease node-01@example.com"
  ];
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  networking.useDHCP = lib.mkDefault true;

  environment.systemPackages = [
    pkgs.git
    pkgs.age
    pkgs.disko
    pkgs.jq
    pkgs.rsync
  ];

  system.stateVersion = "26.11";
}
