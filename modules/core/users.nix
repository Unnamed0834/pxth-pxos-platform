{
  lib,
  config,
  ...
}:

{
  imports = [ ./keys.nix ];

  config =
    let
      ids = import ../runtime/ids.nix;

      present = lib.filterAttrs (name: _: config.users.users ? ${name}) ids;
      pins = lib.concatStringsSep " " (
        lib.mapAttrsToList (name: v: "${name}:${toString v.uid}:${toString v.gid}") present
      );
    in
    {
      users.mutableUsers = false;

      users.allowNoPasswordLogin = lib.mkDefault false;
      users.users.root = {
        hashedPassword = lib.mkForce "!";
        hashedPasswordFile = lib.mkForce null;
      };

      age.secrets.operator-sudo = {
        file = ../../examples/secrets/common/admin-password.env;
        mode = "0400";
      };
      users.users.operator = {
        isNormalUser = true;
        uid = lib.mkDefault 1000;
        hashedPasswordFile = config.age.secrets.operator-sudo.path;
        description = "pxOS Administrator";
        extraGroups = [ "wheel" ] ++ lib.optional config.networking.networkmanager.enable "networkmanager";
        autoSubUidGidRange = false;
        subUidRanges = [ ];
        subGidRanges = [ ];
      };

      system.activationScripts.paxosPinIds = lib.stringAfter [ "users" ] ''
        pins=${lib.escapeShellArg pins}
        for pin in $pins; do
          name=''${pin%%:*}
          rest=''${pin#*:}
          want_uid=''${rest%%:*}
          want_gid=''${rest##*:}

          passwd_line=$(grep "^$name:" /etc/passwd || true)
          if [ -n "$passwd_line" ]; then
            cur_uid=$(printf '%s' "$passwd_line" | cut -d: -f3)
            if [ "$cur_uid" != "$want_uid" ]; then
              new_line=$(printf '%s:%s:%s:%s:%s'               "$(printf '%s' "$passwd_line" | cut -d: -f1)"               "$(printf '%s' "$passwd_line" | cut -d: -f2)"               "$want_uid" "$want_gid"               "$(printf '%s' "$passwd_line" | cut -d: -f5-)")
              grep -v "^$name:" /etc/passwd > /etc/passwd.pinned || true
              printf '%s\n' "$new_line" >> /etc/passwd.pinned
              cat /etc/passwd.pinned > /etc/passwd
              rm -f /etc/passwd.pinned
            fi
          fi

          group_line=$(grep "^$name:" /etc/group || true)
          if [ -n "$group_line" ]; then
            cur_gid=$(printf '%s' "$group_line" | cut -d: -f3)
            if [ "$cur_gid" != "$want_gid" ]; then
              new_line=$(printf '%s:%s:%s:%s'               "$(printf '%s' "$group_line" | cut -d: -f1)"               "$(printf '%s' "$group_line" | cut -d: -f2)"               "$want_gid"               "$(printf '%s' "$group_line" | cut -d: -f4-)")
              grep -v "^$name:" /etc/group > /etc/group.pinned || true
              printf '%s\n' "$new_line" >> /etc/group.pinned
              cat /etc/group.pinned > /etc/group
              rm -f /etc/group.pinned
            fi
          fi
        done
      '';
    };
}
