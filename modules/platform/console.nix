
{ lib, ... }: {
  config = {
    services.getty.autologinUser = lib.mkDefault null;
    systemd.services."getty@".enable = lib.mkDefault true;
    systemd.services."autovt@".enable = lib.mkDefault true;
    systemd.services."serial-getty@".enable = lib.mkDefault true;
  };
}
