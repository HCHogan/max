{
  description = "max — a QQ group chat agent over OneBot 11 (NapCatQQ)";

  inputs = {
    # Pinned to the rev in flake.lock: haskellPackages there is
    # GHC 9.10.3 and the whole closure is in the hydra cache.
    nixpkgs.url = "github:NixOS/nixpkgs/34268251cf5547d39063f2c5ea9a196246f7f3a6";
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
      sandboxSystem =
        system: extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./nix/sandbox-guest.nix ] ++ extraModules;
        };

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
          # Default haskellPackages set (GHC 9.10.3 on the pinned
          # nixpkgs): matches the devenv compiler and the whole dep
          # closure comes from the hydra cache.  9.12.4's set needed
          # everything built from source and its HLS doesn't build.
          hp = pkgs.haskellPackages.override {
            overrides = hself: hsuper: {
              # The set defaults opt-env-conf to 0.9; we use the 0.15
              # API, which the pinned nixpkgs already carries as a
              # versioned attribute -- no callHackageDirect, no sha256
              # to keep up to date, no jailbreak (0.15.0.1 has no upper
              # bounds), no dontCheck (its sdist has no test suite).
              opt-env-conf = hsuper.opt-env-conf_0_15_0_1;
              # dontCheck: max-test-db wants a live PostgreSQL.
              # MAX_GIT_REV: the cleaned source has no .git, so
              # Max.BuildInfo's compile-time splice reads the rev from
              # the environment instead; "unknown" (e.g. a tarball
              # build) renders as no rev at all.
              max = hlib.dontCheck (
                (hself.callCabal2nix "max" (cleanSrc pkgs) { wasmtime = pkgs.wasmtime; }).overrideAttrs (old: {
                  MAX_GIT_REV = self.shortRev or self.dirtyShortRev or "unknown";
                  postInstall = (old.postInstall or "") + ''
                    $out/bin/max --help > /dev/null
                  '';
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
          max-browser = import ./nix/browser.nix { inherit pkgs; };
          max-sandbox = (sandboxSystem system [ ]).config.system.build.toplevel;
        }
      );

      nixosModules = {
        max =
          {
            pkgs,
            lib,
            config,
            ...
          }:
          {
            imports = [ ./nix/module.nix ];
            services.max.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.max;
            services.max.sandbox.package = lib.mkDefault (sandboxSystem pkgs.stdenv.hostPlatform.system config.services.max.sandbox.extraModules)
            .config.system.build.toplevel;
            services.max.sandbox.nixpkgs = lib.mkDefault nixpkgs.outPath;
            services.max.browser.package =
              lib.mkDefault
                self.packages.${pkgs.stdenv.hostPlatform.system}.max-browser;
          };
        default = self.nixosModules.max;
      };

      checks = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          state-migration = import ./nix/tests/state-migration.nix {
            inherit nixpkgs system;
            maxModule = self.nixosModules.max;
          };
          nixos-reload = import ./nix/tests/reload.nix {
            inherit nixpkgs system;
            maxModule = self.nixosModules.max;
          };
          sandbox-network = import ./nix/tests/sandbox-network.nix {
            inherit nixpkgs system;
            maxModule = self.nixosModules.max;
            maxPackage = self.packages.${system}.max;
          };
        }
      );

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
