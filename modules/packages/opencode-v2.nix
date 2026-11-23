
{
  lib,
  stdenv,
  fetchurl,
}:
let
  pin = (import ../runtime/images.nix).opencode;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "opencode-v2";
  inherit (pin) version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${finalAttrs.version}.tgz";
    inherit (pin) hash;
  };

  sourceRoot = "package";
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m 755 bin/opencode $out/bin/opencode
    runHook postInstall
  '';

  meta = {
    description = "OpenCode AI coding agent (V2 CLI)";
    homepage = "https://github.com/anomalyco/opencode";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "opencode";
  };
})
