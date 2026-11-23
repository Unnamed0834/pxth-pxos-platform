
{ lib }: {
  sandbox =
    {
      devices ? false,
      strict ? true,
      umask ? "0077",
      writable ? [ ],
    }:
    {
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = !devices;
      ProtectSystem = if strict then "strict" else "full";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      RestrictNamespaces = true;
      SystemCallArchitectures = "native";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
        "AF_NETLINK"
      ];
      CapabilityBoundingSet = [ "" ];
    }
    // lib.optionalAttrs (umask != null) { UMask = umask; }
    // lib.optionalAttrs (writable != [ ]) { ReadWritePaths = writable; };
}
