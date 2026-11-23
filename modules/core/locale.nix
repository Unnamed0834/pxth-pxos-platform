{ lib, ... }:

{
  config = {
    time.timeZone = lib.mkDefault "UTC";
    i18n.defaultLocale = "en_US.UTF-8";
  };
}
