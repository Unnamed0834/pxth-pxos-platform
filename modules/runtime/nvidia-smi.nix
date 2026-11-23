{
  pkgs,
  lib,
}:
package:
pkgs.writeShellScript "nvidia-smi" ''

  export LD_LIBRARY_PATH=${lib.escapeShellArg "${package.out}/lib"}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

  exec ${lib.escapeShellArg "${pkgs.stdenv.cc.bintools.dynamicLinker}"} \
    ${lib.escapeShellArg "${package.bin}/origBin/nvidia-smi"} \
    "$@"
''
