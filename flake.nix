{
  description = "max — a group chat agent for QQ and Matrix";

  inputs = {
    # The nixpkgs revision nix-config deploys with.
    nixpkgs.url = "github:NixOS/nixpkgs/cd4ea8d57de16f4810bc5f14207bac45fbf19f67";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devenv.url = "github:cachix/devenv/v2.3";
    systems.url = "github:nix-systems/default";
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      crane,
      rust-overlay,
      devenv,
      systems,
      advisory-db,
      ...
    }:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);

      perSystem =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          # rust-toolchain.toml is the only place the compiler version lives.
          toolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
          craneLib = (crane.mkLib pkgs).overrideToolchain (_: toolchain);

          # Cargo's sources plus what the build reads besides: insta's
          # snapshots, max-db's migrations and its offline query data.
          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            name = "source";
            filter =
              path: type:
              craneLib.filterCargoSources path type
              || pkgs.lib.hasSuffix ".snap" path
              || pkgs.lib.hasSuffix ".sql" path
              || pkgs.lib.hasInfix "/.sqlx/" path;
          };
          commonArgs = {
            inherit src;
            # The root Cargo.toml is a workspace and has no package name.
            pname = "max";
            strictDeps = true;
            # sqlx's macros check queries against .sqlx, not a database.
            SQLX_OFFLINE = "true";
          };
          # Dependencies build once and are cached apart from our code.
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          max = craneLib.buildPackage (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoExtraArgs = "--package max";
              doCheck = false; # the nextest check runs the tests
            }
          );

          # A cargo command over the workspace that passes or fails and
          # produces nothing else.
          cargoCheck =
            name: nativeBuildInputs: command:
            craneLib.mkCargoDerivation (
              commonArgs
              // {
                inherit cargoArtifacts nativeBuildInputs;
                pnameSuffix = "-${name}";
                buildPhaseCargoCommand = command;
                doInstallCargoArtifacts = false;
                installPhaseCommand = "mkdir -p $out";
              }
            );
        in
        {
          inherit pkgs toolchain;

          packages = {
            inherit max;
            default = max;
          };

          checks = {
            inherit max;

            fmt = craneLib.cargoFmt commonArgs;

            clippy = craneLib.cargoClippy (
              commonArgs
              // {
                inherit cargoArtifacts;
                cargoClippyExtraArgs = "--all-targets -- --deny warnings";
              }
            );

            nextest = craneLib.cargoNextest (
              commonArgs
              // {
                inherit cargoArtifacts;
                nativeBuildInputs = [ pkgs.postgresql_17 ];
                # #[sqlx::test] makes a scratch database per test on this
                # server. TCP only: a socket path under $TMPDIR can be too
                # long on macOS.
                preCheck = ''
                  export PGDATA="$TMPDIR/postgres"
                  initdb --username=max --auth=trust --locale=C --encoding=UTF8 >/dev/null
                  pg_ctl start --wait --silent --log="$TMPDIR/postgres.log" \
                    --options "-c listen_addresses=127.0.0.1 -c port=54329 -c unix_socket_directories="
                  export DATABASE_URL=postgresql://max@127.0.0.1:54329/postgres
                '';
                postCheck = "pg_ctl stop --mode=fast --silent";
              }
            );

            # Licenses, bans and sources; see deny.toml.
            deny = craneLib.cargoDeny commonArgs;

            # cargo-deny would fetch the advisory database, which the build
            # sandbox can't; cargo-audit reads the pinned advisory-db input.
            audit = craneLib.cargoAudit (commonArgs // { inherit advisory-db; });

            machete = cargoCheck "machete" [ pkgs.cargo-machete ] "cargo machete";

            # max-core may depend only on these. Its transitive dependencies
            # don't matter: they are whatever these four need.
            max-core-deps = cargoCheck "max-core-deps" [ ] ''
              actual=$(cargo tree --package max-core --edges normal --depth 1 \
                --prefix none --format '{p}' | awk 'NR > 1 { print $1 }' | sort -u)
              expected=$(printf '%s\n' chrono serde serde_json thiserror)
              extra=$(comm -23 <(echo "$actual") <(echo "$expected") | sed '/^$/d')
              if [ -n "$extra" ]; then
                echo "max-core depends on crates outside its allow list:" >&2
                echo "$extra" >&2
                exit 1
              fi
            '';

            # Built on its own, max-core gets chrono without the clock that
            # the max crate turns on, so a Utc::now in the core won't compile.
            max-core-alone = cargoCheck "max-core-alone" [ ] "cargo check --package max-core";
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            module = import ./nix/tests/module.nix {
              inherit pkgs;
              module = self.nixosModules.maxx;
            };
          };

          devShell = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              ./devenv.nix
              { packages = [ toolchain ]; }
            ];
          };
        };

      all = forEachSystem perSystem;
    in
    {
      packages = forEachSystem (system: all.${system}.packages);
      # One module per name; see nix/module.nix. tank runs maxx beside the
      # Haskell max until the Rust version takes the name over.
      nixosModules = {
        maxx = import ./nix/module.nix {
          name = "maxx";
          inherit (self) packages;
        };
        max = import ./nix/module.nix {
          name = "max";
          inherit (self) packages;
        };
      };
      checks = forEachSystem (system: all.${system}.checks);
      devShells = forEachSystem (system: {
        default = all.${system}.devShell;
      });
    };
}
