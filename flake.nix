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
              # Marked broken in nixpkgs (stale bounds); it builds fine
              # against the current set once the bounds are relaxed.
              wreq-effectful = hlib.markUnbroken (hlib.doJailbreak hsuper.wreq-effectful);
              # doJailbreak: nixpkgs has effectful 2.6 (our bound says <2.6);
              # dontCheck: max-test-db wants a live PostgreSQL.
              max = hlib.dontCheck (hlib.doJailbreak (hself.callCabal2nix "max" (cleanSrc pkgs) { }));
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
          max-bot = maxPackage pkgs;
          default = maxPackage pkgs;
        }
      );

      nixosModules = {
        max-bot =
          { pkgs, lib, ... }:
          {
            imports = [ ./nix/module.nix ];
            services.max-bot.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.max-bot;
          };
        default = self.nixosModules.max-bot;
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
