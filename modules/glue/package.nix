{
  buildGoModule,
  lib,
}:
let
  palette = import ../platform/board/palette.nix;

in
buildGoModule {
  pname = "paxos-glue";
  version = "0.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "go" || file.name == "go.mod") ./.;
  };

  vendorHash = null;

  preBuild = ''
    substituteInPlace fluxer.go --replace-fail '@accent@' '${palette.siteB.accent}'
  '';
  env = {
    CGO_ENABLED = "0";
    GOPROXY = "off";
    GOTOOLCHAIN = "local";
  };
  meta.mainProgram = "paxos-glue";
}
