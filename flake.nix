{
  description = "pxOS — hardened NixOS hosts (nixos-anywhere + SSH)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
    }:
    let
      system = "x86_64-linux";
      vmToolsOverlay =
        _final: prev:
        let
          wrapVmTools =
            vt:
            vt
            // {
              override =
                newArgs:
                let
                  kernelArg = newArgs.kernel or null;
                  rewritten =
                    if kernelArg != null && !(kernelArg ? target) && !(newArgs ? kernelModules) then
                      newArgs
                      // {
                        kernel = prev.linuxPackages.kernel;
                        kernelModules = kernelArg;
                      }
                    else
                      newArgs;
                in
                wrapVmTools (vt.override rewritten);
            };
        in
        {
          vmTools = wrapVmTools prev.vmTools;
        };

      glueOverlay = final: _prev: {
        paxos-glue = final.callPackage ./modules/glue/package.nix { };
      };

      firecrackerOverlay = final: prev: {
        firecracker = prev.firecracker.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.pkg-config ];
          buildInputs = (old.buildInputs or [ ]) ++ [ final.aws-lc ];
        });
      };

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        config.rocmSupport = true;
        overlays = [
          vmToolsOverlay
          glueOverlay
          firecrackerOverlay
        ];
      };
      inherit (nixpkgs) lib;

      specialArgs = {
        inherit self disko agenix;
        harden = import ./modules/runtime/service-harden.nix { inherit lib; };
        resticEdge = import ./modules/plugins/restic-edge.nix;
      };

      mkConfig =
        modules:
        nixpkgs.lib.nixosSystem {
          inherit system pkgs specialArgs;
          modules = modules ++ [
            disko.nixosModules.disko
            agenix.nixosModules.default
          ];
        };

      hostConfigurations =
        let
          hasConfig =
            family: name: type:
            type == "directory" && builtins.pathExists ./hosts/${family}/${name}/configuration.nix;
          families = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts);
          found = lib.concatLists (
            lib.mapAttrsToList (
              family: _:
              lib.mapAttrsToList (name: _: { inherit family name; }) (
                lib.filterAttrs (hasConfig family) (builtins.readDir ./hosts/${family})
              )
            ) families
          );
          names = map (host: host.name) found;
          dupes = lib.unique (lib.filter (name: lib.count (n: n == name) names > 1) names);
        in
        if dupes != [ ] then
          throw "duplicate host names under hosts/: ${lib.concatStringsSep ", " dupes}"
        else
          lib.listToAttrs (
            map (
              host:
              let
                modules = [ ./hosts/${host.family}/${host.name}/configuration.nix ];
              in
              lib.nameValuePair host.name (mkConfig modules)
            ) found
          );

      installerSystem = mkConfig [ ./bootstrap/installer/configuration.nix ];

      hostPackages = lib.mapAttrs' (
        name: configuration: lib.nameValuePair "host-${name}" configuration.config.system.build.toplevel
      ) hostConfigurations;

      vmaPackages = lib.mapAttrs' (
        name: configuration: lib.nameValuePair "${name}-vma" configuration.config.system.build.paxosVMA
      ) (lib.filterAttrs (_: c: c.config.paxos.pve.enable or false) hostConfigurations);
    in
    {
      nixosConfigurations = hostConfigurations;

      packages.${system} = {
        default = self.nixosConfigurations.bsn.config.system.build.toplevel;
        installer-iso = installerSystem.config.system.build.isoImage;
        board-mono = import ./modules/platform/board/font.nix { inherit pkgs; };
        opencode-v2 = pkgs.callPackage ./modules/packages/opencode-v2.nix { };
        inherit (pkgs) paxos-glue;
      }
      // hostPackages
      // vmaPackages;

      devShells.${system} = {
        default = pkgs.mkShell {
          env = {
            CGO_ENABLED = "0";
            GOTOOLCHAIN = "local";
            GOPROXY = "off";
          };
          buildInputs = [
            pkgs.coreutils
            pkgs.age
            pkgs.openssh
            pkgs.nixos-rebuild
            pkgs.python312Packages.pytest
            pkgs.go
            pkgs.nixfmt
            pkgs.statix
            pkgs.deadnix
            pkgs.shellcheck
            pkgs.gitleaks
          ];
        };

        scan = pkgs.mkShell {
          buildInputs = [
            pkgs.trivy
            pkgs.grype
            pkgs.syft
            pkgs.skopeo
          ];
        };
      };
    };
}
