


let
  ground = {
    board = "#15110f";
    card = "#241c18";
    hover = "#2b2420";
    well = "#2b2420";
    line = "#3c2c24";
    line2 = "#6a5f57";
    ink = "#f1e8e1";
    body = "#c4bbb4";
    muted = "#8a837e";

    hairline = "#f1e8e1";


    onAccent = "#15110f";

    link = "#f1e8e1";
    boardRgb = "21, 17, 15";

    ramp1 = "#3c2c24";
    ramp2 = "#6a5f57";
    ramp3 = "#c4bbb4";
    ramp4 = "#f1e8e1";

    laneAux = "#7fa6b8";


    dividerRgb = "241, 232, 225";

    fontMono = "'Board Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";


    band = "rgba(138, 131, 126, 0.15)";

    divider = "#f1e8e1";
  };
  series =
    accent: accentHover: accentDark:
    ground
    // {
      inherit
        accent
        accentHover
        accentDark
        ;
    };
in
{
  siteC = series "#ddaa8a" "#e4c0a8" "#c49478";
  siteB = series "#7fa6b8" "#a7bdc6" "#688494";
}
