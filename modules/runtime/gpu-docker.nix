
{
  pkgs,
  config,
  lib,
}:
let
  driverLib = "${config.hardware.nvidia.package}/lib";
  driverLibs = [
    "libcuda.so.1"
    "libnvidia-ml.so.1"
    "libnvidia-cfg.so.1"
  ];
  driverLibsWithPtx = driverLibs ++ [ "libnvidia-ptxjitcompiler.so.1" ];

  splitIds = gpus: lib.filter (s: s != "") (lib.splitString "," gpus);

  mkGpuDevices =
    gpus:
    lib.concatStringsSep " " (
      [
        "/dev/nvidiactl"
        "/dev/nvidia-uvm"
      ]
      ++ lib.map (i: "/dev/nvidia${i}") (splitIds gpus)
    );

  mkVisibleGpus = gpus: lib.concatStringsSep "," (lib.genList toString (lib.length (splitIds gpus)));

  mkGpuEnv = gpus: {
    CUDA_VISIBLE_DEVICES = gpus;
    LD_LIBRARY_PATH = driverLib;
  };

  gpuMountHelpers = pkgs.writeShellScript "gpu-mount-helpers" ''
    gpuDevArgs() {
      local -n _out="$1"
      local _d
      for _d in ''${2:-}; do _out+=( --device "$_d" ); done
    }
    gpuLibMounts() {
      local -n _out="$1"
      local _libdir="''${2:-}" _l
      if [ -z "$_libdir" ]; then return 0; fi
      for _l in ${lib.concatStringsSep " " driverLibsWithPtx}; do
        [ -f "$_libdir/$_l" ] || { echo "missing driver lib: $_libdir/$_l" >&2; exit 1; }
        _out+=( -v "$_libdir/$_l:/usr/lib/x86_64-linux-gnu/$_l:ro" )
      done
    }
    gpuEnvArgs() {
      local -n _out="$1"
      if [ -n "''${2:-}" ]; then _out+=( -e CUDA_VISIBLE_DEVICES="$2" ); fi
    }
  '';
in
{
  inherit
    driverLib
    driverLibs
    driverLibsWithPtx
    mkGpuDevices
    mkVisibleGpus
    mkGpuEnv
    gpuMountHelpers
    ;
}
