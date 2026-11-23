{ lib, ... }:

{
  config = {
    console = {
      enable = true;
      earlySetup = lib.mkDefault true;
      colors = [
        "0f0c08"
        "cc4400"
        "d97706"
        "ffb000"
        "8b5a2b"
        "ff7800"
        "ffc247"
        "ffd480"
        "4a3300"
        "ff3030"
        "6eff4a"
        "ffc72c"
        "d97706"
        "ff9233"
        "ffdb99"
        "fff5e6"
      ];
    };
  };
}
