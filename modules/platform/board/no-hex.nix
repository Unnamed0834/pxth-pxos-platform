

let
  dir = ./.;
  cssNames = builtins.filter (name: builtins.match ".*\\.css" name != null) (
    builtins.attrNames (builtins.readDir dir)
  );
  linesOf = text: builtins.filter builtins.isString (builtins.split "\n" text);
  isHex = line: builtins.match ".*#[0-9A-Fa-f]{3,8}([^0-9A-Fa-f].*)?" line != null;
  isRawRgba =
    line: builtins.match ".*rgba\\(.*" line != null && builtins.match ".*@boardRgb@.*" line == null;
  problems = builtins.concatMap (
    name:
    let
      lines = linesOf (builtins.readFile (dir + "/${name}"));
    in
    map (line: "${name}: ${line}") (builtins.filter (line: isHex line || isRawRgba line) lines)
  ) cssNames;
in
if problems == [ ] then
  true
else
  throw "portal sheet still hardcodes a color:\n${builtins.concatStringsSep "\n" problems}"
