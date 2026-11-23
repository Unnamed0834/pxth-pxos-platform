{
  config,
  lib,
  pkgs,
  ...
}:


let
  cfg = config.paxos.pve;


  endpoints = {
    hypervisor-01 = {
      host = "192.0.2.10";
      storage = "pool0";
      bridge = "vmbr0";
    };
  };
  endpoint =
    endpoints.${cfg.node}
      or (throw "unknown paxos.pve.node '${cfg.node}' (want one of: ${lib.concatStringsSep ", " (builtins.attrNames endpoints)})");
  specId = config.paxos.spec.id or "guest";
  suffix = "${toString cfg.vmid}-${specId}";
  imageBase = "vzdump-qemu-${suffix}";

  qemuServerConf = pkgs.writeText "qemu-server.conf" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k}: ${toString v}") (
        {
          name = specId;
          ostype = "l26";
          inherit (cfg) cores;
          inherit (cfg) memory;
          bios = "ovmf";
          scsihw = "virtio-scsi-single";
          agent = 1;
          serial0 = "socket";
          boot = "order=scsi0";
          scsi0 = "${cfg.storage}:vm-${toString cfg.vmid}-disk-1,iothread=1";


          net0 = "virtio=00:00:00:00:00:00,bridge=${cfg.bridge},firewall=1,tag=${toString cfg.vlan}";
        }
        // lib.optionalAttrs (!cfg.balloon) {

          balloon = 0;
        }
        // cfg.qemuExtraConf
      )
      ++ [ "#qmdump#map:scsi0:drive-scsi0:${cfg.storage}:raw:" ]
    )
  );


  vmaQemu =
    (pkgs.qemu_kvm.override {
      alsaSupport = false;
      pulseSupport = false;
      sdlSupport = false;
      jackSupport = false;
      gtkSupport = false;
      vncSupport = false;
      smartcardSupport = false;
      spiceSupport = false;
      ncursesSupport = false;
      libiscsiSupport = false;
      tpmSupport = false;
      numaSupport = false;
      seccompSupport = false;
      guestAgentSupport = false;
    }).overrideAttrs
      (super: rec {
        version = "9.0.0";
        src = pkgs.fetchurl {
          url = "https://download.qemu.org/qemu-${version}.tar.xz";
          hash = "sha256-MnCKxmww2MiSYz6paMdxwcdtWX1w3erSGg0izPOG2mk=";
        };
        patches = [
          "${
            pkgs.fetchFromGitHub {
              owner = "proxmox";
              repo = "pve-qemu";
              rev = "14afbdd55f04d250bd679ca1ad55d3f47cd9d4c8";
              hash = "sha256-lSJQA5SHIHfxJvMLIID2drv2H43crTPMNIlIT37w9Nc=";
            }
          }/debian/patches/pve/0027-PVE-Backup-add-vma-backup-format-code.patch"
        ];
        buildInputs = super.buildInputs ++ [ pkgs.libuuid ];
        nativeBuildInputs = super.nativeBuildInputs ++ [ pkgs.perl ];
      });

  paxosVMA =
    pkgs.runCommand imageBase
      {
        nativeBuildInputs = [
          vmaQemu
          pkgs.zstd
          pkgs.coreutils
        ];
        meta.description = "EYD disko disk wrapped as Proxmox VMA for ${specId}";
      }
      ''
        set -euo pipefail
        raw=$(echo ${config.system.build.diskoImages}/*.raw)
        test -f "$raw"
        cp ${qemuServerConf} qemu-server.conf
        ${vmaQemu}/bin/vma create "${imageBase}.vma" \
          -c qemu-server.conf drive-scsi0="$raw"
        ${pkgs.zstd}/bin/zstd -T0 "${imageBase}.vma"
        mkdir -p "$out"
        mv "${imageBase}.vma.zst" "$out/"
      '';
in
{
  options.paxos.pve = {
    enable = lib.mkEnableOption "Proxmox VMA image from disko-eyd (PVE guests only)";

    node = lib.mkOption {
      type = lib.types.str;
      default = "hypervisor-01";
      description = "Proxmox node name: selects the endpoint (host/storage/bridge) from the table above. Standalone nodes only — never clustered.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = endpoint.host;
      description = "SSH target for qmrestore. Defaults from paxos.pve.node.";
    };

    vmid = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Proxmox VMID (also prefixes the VMA filename).";
    };

    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
    };

    memory = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Guest RAM in MiB.";
    };

    diskGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64;
      description = "Target SCSI disk size after restore (qm resize). Image build uses imageSize.";
    };

    balloon = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep PVE's stock balloon device (it already carries
        free-page-reporting) so the hypervisor can reclaim idle guest page
        cache under host memory pressure. Without it the balloon stays pinned
        at maxmem and guests hoard cache the host can never take back — that
        is what made the host look full.

        Set false on GPU-passthrough hosts: their resident memory is engine
        working set, not page cache, and reclaiming under a live vLLM engine
        is not worth the risk. Emits balloon: 0 in that case.
      '';
    };

    imageSize = lib.mkOption {
      type = lib.types.str;
      default = "16G";
      description = "diskoImages qemu-img size (store-backed; keep smaller than diskGiB).";
    };

    swapGiB = lib.mkOption {

      type = lib.types.ints.between 0 256;
      default = 0;
      description = ''
        Disk swapfile on /nix, in GiB. 0 disables it.

        Do NOT also declare /nix/swapfile in `swapDevices` when this is set:
        this module deliberately removes it so systemd generates no
        mkswap-*.service/*.swap unit and puts no file swap in swap.target.
        See the swapfile-ensure unit for why that matters.
      '';
    };

    storage = lib.mkOption {
      type = lib.types.str;
      default = endpoint.storage;
      description = "PVE storage id for scsi0 / EFI / qmrestore --storage. Defaults from paxos.pve.node.";
    };

    dumpStorage = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = "PVE dump storage to drop the .vma.zst (usually local).";
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = endpoint.bridge;
      description = "Guest bridge. Defaults from paxos.pve.node.";
    };

    vlan = lib.mkOption {
      type = lib.types.ints.u16;
      description = "VLAN tag on net0.";
    };

    qemuExtraConf = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
        ]
      );
      default = { };
      description = "Extra qemu-server.conf keys (hostpci, cpu, onboot, …).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.node endpoints;
        message = "paxos.pve.node " + cfg.node + " is not a known endpoint (want hypervisor-01)";
      }
      {
        assertion = config.paxos.spec.id != null;
        message = "paxos.pve.enable requires paxos.spec.id";
      }
      {
        assertion = config.paxos.ephemeral.enable;
        message = "paxos.pve.enable is the EYD VMA path; do not enable on durable-root hosts";
      }
      {
        assertion = config.boot.loader.systemd-boot.enable;
        message = "paxos.pve.enable requires systemd-boot + OVMF";
      }
      {
        assertion =
          cfg.swapGiB == 0 || builtins.all (s: s.device or "" != "/nix/swapfile") config.swapDevices;
        message = ''
          paxos.pve.swapGiB is set, so /nix/swapfile must not also appear in
          swapDevices: systemd would generate its own dd-based mkswap unit
          that races paxos-grow-rootfs for the same file. See the
          swapfile-ensure unit in modules/hardware/pve-vma.nix.
        '';
      }
    ];

    disko.memSize = lib.mkDefault 4096;
    disko.devices.disk.main.imageSize = cfg.imageSize;
    disko.devices.disk.main.imageName = "paxos-${specId}";

    fileSystems."/boot".neededForBoot = true;


    systemd.services.paxos-grow-rootfs = {
      description = "Grow GPT nix partition and ext4 to fill the resized PVE disk";
      wantedBy = [ "multi-user.target" ];
      after = [ "nix.mount" ];
      before = [
        "agenix-decrypt.service"
        "restic-bootstrap.service"
      ];
      path = [
        pkgs.util-linux
        pkgs.e2fsprogs
        pkgs.cloud-utils
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        src=$(findmnt -n -o SOURCE /nix)
        name=''${src#/dev/}
        disk=""; part=""
        case "$name" in
          nvme*n*p*)
            disk=/dev/''${name%p*}
            part=''${name##*p}
            ;;
          *mmcblk*p*)
            disk=/dev/''${name%p*}
            part=''${name##*p}
            ;;
          *[0-9])
            disk=/dev/''${name%%[0-9]*}
            part=''${name#"''${disk#/dev/}"}
            ;;
        esac
        echo "paxos-grow-rootfs: $src (disk=$disk part=$part)"
        if [ -n "$disk" ] && [ -n "$part" ]; then
          growpart "$disk" "$part" || true
        fi
        resize2fs "$src"
      '';
    };

    systemd.services.swapfile-ensure = lib.mkIf (cfg.swapGiB > 0) {
      description = "Create and activate the /nix swapfile after paxos-grow-rootfs";
      wantedBy = [ "multi-user.target" ];
      after = [ "paxos-grow-rootfs.service" ];
      requires = [ "paxos-grow-rootfs.service" ];
      path = [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        f=/nix/swapfile
        want=$(( ${toString cfg.swapGiB} * 1024 * 1024 * 1024 ))
        if [ ! -f "$f" ] || [ "$(stat -c %s "$f")" -ne "$want" ]; then
          swapoff "$f" 2>/dev/null || true
          rm -f "$f"
          fallocate -l ${toString cfg.swapGiB}G "$f"
          chmod 600 "$f"
          mkswap "$f" >/dev/null
        fi
        if ! grep -qE "^$f[[:space:]]" /proc/swaps; then
          mkswap "$f" >/dev/null 2>&1 || true
          swapon "$f"
        fi
      '';
    };

    system.build.paxosVMA = paxosVMA;
    system.build.paxosQemuServerConf = qemuServerConf;
  };
}
