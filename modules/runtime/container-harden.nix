
let
  noNewPrivilegesFlag = "--security-opt=no-new-privileges:true";

  dangerousTokens = [
    "--privileged"
    "--network=host"
    "--network host"
    "--pid=host"
    "--pid host"
    "docker.sock"
    "containerd.sock"
  ];
  hasToken =
    token: text:
    let
      escaped = builtins.replaceStrings [ "." ] [ "\\." ] token;
    in
    builtins.match (".*" + escaped + ".*") text != null;
  demandOptIn =
    name: text: allow:
    let
      hits = builtins.filter (token: hasToken token text) dangerousTokens;
    in
    if hits != [ ] && !allow then
      throw ''
        container ${name} uses ${builtins.concatStringsSep ", " hits}.
        Set allowDangerous = true on that container. Privileged mode, host
        network, host pid, and engine socket mounts are refused unless the
        module opts in.
      ''
    else
      text;
  ownerCapFlags = [
    "--cap-add=CHOWN"
    "--cap-add=DAC_OVERRIDE"
    "--cap-add=FOWNER"
    "--cap-add=SETGID"
    "--cap-add=SETUID"
    "--cap-add=KILL"
  ];
  options = [
    noNewPrivilegesFlag
    "--cap-drop=ALL"
  ];
  join = builtins.concatStringsSep " ";
  opt = cond: value: if cond then [ value ] else [ ];
in
{
  inherit options ownerCapFlags;
  flags = join options;

  run =
    {
      podman,
      name,
      image,
      pod ? null,
      detach ? false,
      replace ? false,
      user ? null,
      noNewPrivileges ? true,
      ownerCaps ? false,
      caps ? [ ],
      args ? "",
      command ? "",
      ignoreFailure ? false,
      allowDangerous ? false,
    }:
    let
      bin = if ignoreFailure then "-${podman}" else podman;
      line = join (
        [
          bin
          "run"
        ]
        ++ opt detach "-d"
        ++ opt replace "--replace"
        ++ [
          "--name"
          name
        ]
        ++ opt (pod != null) "--pod ${pod}"
        ++ opt (user != null) "--user ${user}"
        ++ opt noNewPrivileges noNewPrivilegesFlag
        ++ [ "--cap-drop=ALL" ]
        ++ (if ownerCaps then ownerCapFlags else [ ])
        ++ map (cap: "--cap-add=${cap}") caps
        ++ opt (args != "") args
        ++ [ image ]
        ++ opt (command != "") command
      );
    in
    builtins.seq (demandOptIn name line allowDangerous) line;

  container =
    cfg:
    let
      rendered = builtins.concatStringsSep "\n" ((cfg.volumes or [ ]) ++ (cfg.extraOptions or [ ]));
    in
    builtins.seq (demandOptIn (cfg.image or "oci") rendered (cfg.allowDangerous or false)) (
      builtins.removeAttrs cfg [
        "extraOptions"
        "ownerCaps"
        "allowDangerous"
      ]
      // {
        extraOptions =
          options ++ (if cfg.ownerCaps or false then ownerCapFlags else [ ]) ++ (cfg.extraOptions or [ ]);
      }
    );

  compose =
    {
      pkgs,
      docker,
      name,
      file,
      projectDirectory ? null,
      services,
      allowDangerous ? false,
    }:
    let
      capName = flag: builtins.replaceStrings [ "--cap-add=" ] [ "" ] flag;
      nnpValue = builtins.replaceStrings [ "--security-opt=" ] [ "" ] noNewPrivilegesFlag;
      shellArg = arg: "'${builtins.replaceStrings [ "'" ] [ "'\\''" ] (builtins.toString arg)}'";
      serviceBlock =
        svc:
        let
          nnp = svc.noNewPrivileges or true;
          capAdds = (if svc.ownerCaps or false then map capName ownerCapFlags else [ ]) ++ (svc.caps or [ ]);
          body = builtins.concatStringsSep "\n" (
            [ "  ${svc.name}:" ]
            ++ [ "    cap_drop:" ]
            ++ [ "      - ALL" ]
            ++ opt nnp "    security_opt:"
            ++ opt nnp "      - ${nnpValue}"
            ++ opt (capAdds != [ ]) "    cap_add:"
            ++ map (cap: "      - ${cap}") capAdds
          );
        in
        demandOptIn svc.name body (svc.allowDangerous or false);
      override = pkgs.writeText "${name}-cap-drop.yml" (
        "services:\n" + builtins.concatStringsSep "\n" (map serviceBlock services) + "\n"
      );
      command =
        verb:
        demandOptIn name (join (
          [
            "${docker} compose"
            "-f"
            (shellArg file)
            "-f"
            (shellArg override)
          ]
          ++ opt (projectDirectory != null) "--project-directory ${shellArg projectDirectory}"
          ++ [ verb ]
        )) allowDangerous;
      up = command "up";
      stop = command "stop";
      down = command "down";
    in
    builtins.seq (up + stop + down) {
      inherit
        up
        stop
        down
        override
        ;
    };
}
