{
  specId,
  vmid ? null,
  address,
  uuid,
  tokenSecret,
}:
{
  pkgs,
  lib,
  ...
}:
let
  site = import ../sites/site-a.nix;
  images = import ../runtime/images.nix;
  nixImage = images.nixosNix;
  runnerNixConfig = ''
    experimental-features = nix-command flakes
    substituters = https://cache.example.com https://cache.nixos.org
    fallback = true
  '';
  imageScanScratch = "/persist/image-scan-scratch";
  deployScratch = "/persist/deploy-scratch";
in
{
  imports = [
    (import ./guest.nix {
      inherit specId vmid address;
      inherit (site) domain;
      vlan = 3002;
      imports = [ ];
      cores = 4;
      memory = 4096;
      swapGiB = 4;
      diskGiB = 50;
      imageSize = "16G";
      firewall.tcp = [ ];
    })
  ];

  paxos.ephemeral.rootSize = "6G";

  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "daily";
    };
  };

  age.secrets.forgejo-runner-token = {
    file = tokenSecret;
    mode = "0400";
  };

  services.forgejo-runner.instances.r = {
    enable = true;
    settings = {
      server.connections.default = {
        url = "https://git.example.com/";
        inherit uuid;
      };
      runner = {
        capacity = 1;
        labels = [
          "nix:docker://${nixImage}"
          "node:docker://node:22-bookworm"
        ];
      };
      container = {
        network = "";
        privileged = false;
        docker_host = "-";
        valid_volumes = [
          imageScanScratch
          deployScratch
        ];
        options = "--memory=3000m --cpus=2 -v ${imageScanScratch}:/image-scan-scratch -v ${deployScratch}:/deploy-scratch --env ${lib.escapeShellArg "NIX_CONFIG=${runnerNixConfig}"} --env ${lib.escapeShellArg "PAXOS_RUNNER_ADDRESS=${address}"}";
      };
    };
    secrets.server.connections.default.token_url = "/run/agenix/forgejo-runner-token";
  };

  systemd.tmpfiles.rules = [
    "d ${imageScanScratch} 0755 root root -"
    "d ${imageScanScratch}/db 0755 root root -"
    "d ${imageScanScratch}/work 0755 root root -"
    "d ${deployScratch} 0755 root root -"
    "f ${deployScratch}/runner-address 0644 root root - ${address}"
  ];

  systemd.services."forgejo-runner-r" = {
    after = [ "agenix-decrypt.service" ];
    wants = [ "agenix-decrypt.service" ];
    requires = [ "agenix-decrypt.service" ];
    preStart = ''
      mkdir -p ${imageScanScratch}/db ${imageScanScratch}/work
      shopt -s nullglob dotglob
      for child in ${imageScanScratch}/work/*; do
        rm -rf -- "$child"
      done
    '';
  };

  systemd.services.runner-nightly-reboot = {
    description = "Nightly reboot of stateless runner (wipe job residue)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl reboot";
    };
  };
  systemd.timers.runner-nightly-reboot = {
    description = "Reboot stateless runner nightly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "03:30";
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
  };
}
