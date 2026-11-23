

{
  device ? "/dev/sda",
  rootFs ? "ext4",
  rootSize ? "2G",
}:
_: {
  disko.devices = {
    disk.main = {
      type = "disk";
      inherit device;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              extraArgs = [
                "-n"
                "ESP"
              ];
              mountpoint = "/boot";
              mountOptions = [
                "umask=0077"
                "nosuid"
                "nodev"
                "noexec"
              ];
            };
          };
          nix = {
            size = "100%";
            content = {
              type = "filesystem";
              format = rootFs;
              extraArgs =
                if rootFs == "ext4" then
                  [
                    "-L"
                    "nixos"
                  ]
                else
                  [
                    "-L"
                    "nixos-nix"
                  ];
              mountpoint = "/nix";
              mountOptions = [ "noatime" ];


              postMountHook = ''
                mkdir -p /mnt/nix/persist/secrets /mnt/nix/persist/etc /mnt/nix/persist/ssh
                chmod 700 /mnt/nix/persist/secrets
                mid=/mnt/nix/persist/etc/machine-id
                if [ -d "$mid" ]; then rm -rf "$mid"; fi
                if [ ! -s "$mid" ]; then
                  uuid=$(cat /proc/sys/kernel/random/uuid)
                  a=''${uuid%%-*}; rest=''${uuid#*-}
                  b=''${rest%%-*}; rest=''${rest#*-}
                  c=''${rest%%-*}; rest=''${rest#*-}
                  d=''${rest%%-*}; e=''${rest#*-}
                  printf '%s' "$a$b$c$d$e" > "$mid"
                  chmod 644 "$mid"
                fi
              '';
            };
          };
        };
      };
    };

    nodev."/" = {
      fsType = "tmpfs";
      mountOptions = [
        "defaults"
        "size=${rootSize}"
        "mode=755"
        "nosuid"
        "nodev"
      ];
    };


    nodev."/persist" = {
      fsType = "none";
      device = "/nix/persist";
      mountOptions = [ "bind" ];
    };
  };
}
