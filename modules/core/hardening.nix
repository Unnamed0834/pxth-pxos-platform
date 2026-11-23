{
  pkgs,
  lib,
  ...
}:

{
  config = {

    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages;


    security.protectKernelImage = lib.mkDefault true;
    security.forcePageTableIsolation = lib.mkDefault true;


    boot.tmp.useTmpfs = true;
    fileSystems."/dev/shm" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "nosuid"
        "nodev"
      ];
      neededForBoot = true;
    };


    documentation.enable = lib.mkDefault false;
    documentation.nixos.enable = lib.mkDefault false;
    documentation.man.enable = lib.mkDefault false;
    documentation.info.enable = lib.mkDefault false;
    documentation.doc.enable = lib.mkDefault false;
    environment.defaultPackages = lib.mkDefault [ ];

    systemd.coredump.enable = lib.mkDefault false;
    systemd.settings.Manager.DefaultLimitCORE = "0";
    systemd.tmpfiles.rules = [ "r /core.* - - - -" ];

    services.journald.settings.Journal = {
      SystemMaxUse = "256M";
      RuntimeMaxUse = "32M";
      SystemMaxFileSize = "16M";
    };


    zramSwap = {
      enable = lib.mkDefault true;
      algorithm = lib.mkDefault "zstd";
      memoryPercent = lib.mkDefault 50;
    };


    boot.blacklistedKernelModules = [

      "dccp"
      "sctp"
      "rds"
      "tipc"
      "n-hdlc"
      "ax25"
      "netrom"
      "x25"


      "cramfs"
      "freevxfs"
      "jffs2"
      "hfs"
      "hfsplus"
      "udf"


      "firewire-core"

      "usb-storage"
      "uas"
    ];


    boot.kernel.sysctl = {

      "kernel.dmesg_restrict" = true;
      "kernel.kptr_restrict" = 2;
      "kernel.perf_event_paranoid" = 2;
      "kernel.unprivileged_bpf_disabled" = 1;
      "kernel.yama.ptrace_scope" = 2;
      "kernel.kexec_load_disabled" = 1;
      "kernel.core_pattern" = "/dev/null";
      "dev.tty.ldisc_autoload" = 0;
      "net.core.bpf_jit_harden" = 2;


      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
      "fs.protected_hardlinks" = 1;
      "fs.protected_symlinks" = 1;
      "fs.suid_dumpable" = 0;


      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      "net.ipv6.conf.all.accept_source_route" = 0;
      "net.ipv6.conf.default.accept_source_route" = 0;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.secure_redirects" = 0;
      "net.ipv4.conf.default.secure_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv6.conf.all.accept_ra" = 0;
      "net.ipv6.conf.default.accept_ra" = 0;
      "net.ipv4.conf.all.log_martians" = true;
      "net.ipv4.conf.default.log_martians" = true;
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.tcp_rfc1337" = 1;
    };

    boot.kernelParams = [
      "console=ttyS0,115200n8"
      "console=tty1"
      "mem_sleep_default=s2idle"

      "lockdown=none"


      "slab_nomerge"
      "init_on_alloc=1"
      "init_on_free=1"
      "page_alloc.shuffle=1"
      "pti=on"
      "vsyscall=none"
      "debugfs=off"
      "oops=panic"
      "randomize_kstack_offset=on"
      "iommu.strict=1"
    ];

    security.polkit.enable = true;

    security.sudo = {
      enable = true;
      wheelNeedsPassword = true;
      execWheelOnly = true;

      extraConfig = ''
        Defaults:operator timestamp_timeout=15
      '';
    };

    services.openssh.settings.Banner = "${pkgs.writeText "ssh-banner" ''
      This system is for authorized use only. Access is logged.
    ''}";
    services.getty.helpLine = "This system is for authorized use only. Access is logged.";
    security.apparmor = {
      enable = true;
      packages = [ pkgs.apparmor-profiles ];
    };
    boot.swraid.mdadmConf = lib.mkDefault ''
      MAILADDR root
      HOMEHOST <ignore>
      AUTO +all
      DEVICE partitions
    '';

    system.etc.overlay.mutable = false;
  };
}
