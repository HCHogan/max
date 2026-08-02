{
  description = "max — a QQ group chat agent over OneBot 11 (NapCatQQ)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    devenv.url = "github:cachix/devenv";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      devenv,
      systems,
      ...
    }:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);

      # Source tree for the nix build, minus the fat dev directories
      # (dist-newstyle alone would drag gigabytes into the store).
      cleanSrc =
        pkgs:
        pkgs.lib.cleanSourceWith {
          src = ./.;
          filter =
            path: type:
            let
              b = baseNameOf path;
            in
            pkgs.lib.cleanSourceFilter path type
            && b != "dist-newstyle"
            && b != ".devenv"
            && b != ".direnv"
            && b != ".napcat"
            && b != "var";
        };

      maxPackage =
        pkgs:
        let
          hlib = pkgs.haskell.lib.compose;
          # Default haskellPackages set (GHC 9.10.3 on 25.11): matches
          # the devenv compiler and the whole dep closure comes from the
          # hydra cache.  9.12.4's set needed everything built from
          # source and its HLS doesn't build.
          hp = pkgs.haskellPackages.override {
            overrides = hself: hsuper: {
              # nixpkgs 25.11 ships opt-env-conf 0.9; we use the 0.15 API.
              opt-env-conf = hlib.dontCheck (
                hlib.doJailbreak (
                  hself.callHackageDirect {
                    pkg = "opt-env-conf";
                    ver = "0.15.0.1";
                    sha256 = "sha256-jqLCaD+NhNvLsuF9MuMNlxvTSnTTgxzk4Teth2yfm5k=";
                  } { }
                )
              );
              # dontCheck: max-test-db wants a live PostgreSQL.
              # MAX_GIT_REV: the cleaned source has no .git, so
              # Max.BuildInfo's compile-time splice reads the rev from
              # the environment instead; "unknown" (e.g. a tarball
              # build) renders as no rev at all.
              max = hlib.dontCheck (
                (hself.callCabal2nix "max" (cleanSrc pkgs) { }).overrideAttrs (_: {
                  MAX_GIT_REV = self.shortRev or self.dirtyShortRev or "unknown";
                })
              );
            };
          };
        in
        pkgs.haskell.lib.compose.justStaticExecutables hp.max;
    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          max = maxPackage pkgs;
          default = maxPackage pkgs;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          camoufox-browser = (import ./nix/camoufox-browser.nix { inherit pkgs; }).bundle;
        }
      );

      nixosModules = {
        max =
          { pkgs, lib, ... }:
          {
            imports = [ ./nix/module.nix ];
            services.max.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.max;
          };
        default = self.nixosModules.max;
      };

      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [ ./devenv.nix ];
          };
        }
      );
    };
}
