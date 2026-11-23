

{
  pkgs,
  lib,
}:
let
  palettes = import ./board/palette.nix;

  palettePairs =
    site:
    let
      palette = palettes.${site} or (throw "unknown board site ${site}");
    in
    builtins.sort (a: b: builtins.stringLength a.from > builtins.stringLength b.from) (
      map (token: {
        from = "@${token}@";
        to = palette.${token};
      }) (builtins.attrNames palette)
    );
  fill =
    site: text:
    let
      pairs = palettePairs site;
    in
    builtins.replaceStrings (map (p: p.from) pairs) (map (p: p.to) pairs) text;
  controlsCss = builtins.readFile ./board/controls.css;
  render = site: name: fill site (builtins.readFile (./board + "/${name}.css") + controlsCss);
  fillFile =
    site: name: file:
    let
      script = builtins.toFile "board-subst.sed" (
        lib.concatMapStrings (p: "s|${p.from}|${p.to}|g\n") (palettePairs site)
      );
    in
    pkgs.runCommand name { } ''
      sed -f ${script} ${file} > $out
    '';
  siteOf =
    host:
    if lib.hasInfix "example.org" host then
      "siteB"
    else if lib.hasInfix "example.com" host then
      "siteC"
    else
      throw "no board for ${host}";
  jellyfinSheets = map (site: builtins.replaceStrings [ "\n" ] [ " " ] (render site "jellyfin")) [
    "siteC"
    "siteB"
  ];

  bust = css: "?v=${builtins.substring 0 12 (builtins.hashString "sha256" css)}";

  fontFarm = import ./board/font.nix { inherit pkgs; };
  fontsPath = "/board-fonts";
  snippetQuery =
    query: hosts: css:
    let
      root = pkgs.linkFarm "board-css" (
        map (host: {
          name = "${host}.css";
          path = pkgs.writeText "board.css" css;
        }) hosts
      );
      hostList = lib.concatStringsSep " " hosts;


      token = builtins.replaceStrings [ "." ] [ "-" ] (builtins.head hosts);
    in
    if hosts == [ ] then
      ""
    else
      ''
        @boardcss-${token} {
          host ${hostList}
          path /board.css
        }
        handle @boardcss-${token} {
          root * ${root}
          rewrite * /{http.request.host}.css
          file_server
        }
        @boardfonts-${token} {
          host ${hostList}
          path ${fontsPath}/*
        }
        handle @boardfonts-${token} {
          root * ${fontFarm}
          header Cache-Control "public, max-age=31536000, immutable"
          file_server
        }
        @boardhtml-${token} host ${hostList}
        replace @boardhtml-${token} {
          match {
            header Content-Type text/html*
          }
          "</head>" "<link rel=\"stylesheet\" href=\"/board.css${query}\"></head>"
        }
      '';
  snippet = snippetQuery "";
  snippetBust = hosts: css: snippetQuery (bust css) hosts css;
in
assert import ./board/no-hex.nix;

assert builtins.all (sheet: builtins.match ".*[<&].*" sheet == null) jellyfinSheets;


assert builtins.all
  (weight: lib.hasInfix ''url("${fontsPath}/board-mono-${weight}.woff2")'' controlsCss)
  [
    "400"
    "600"
  ];
{
  inherit
    bust
    fill
    fillFile
    palettes
    render
    siteOf
    snippet
    snippetBust
    ;
}
