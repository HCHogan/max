{
  description = "max — a group chat agent for QQ";

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
    # The groups' VMs: the guest's NixOS modules for cloud-hypervisor.
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # pi, the background agents, in the guest. Its RPC has no version:
    # job::pi's tests replay what this one (pi 1.4.0) said, so moving the
    # pin means recording again and running them.
    llm-agents.url = "github:numtide/llm-agents.nix/e452052b9efb54fd59f8a06cbc09978fb542a3c2";
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
      microvm,
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
          # snapshots, max-db's migrations and its offline query data,
          # max-llm's recorded responses, and the guest's runner and its
          # SDK, which max's tests run with Node.
          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            name = "source";
            filter =
              path: type:
              craneLib.filterCargoSources path type
              || pkgs.lib.hasSuffix ".snap" path
              || pkgs.lib.hasSuffix ".sql" path
              || pkgs.lib.hasSuffix ".sse" path
              || pkgs.lib.hasInfix "/.sqlx/" path
              || pkgs.lib.hasSuffix "/nix/runner.js" path
              || pkgs.lib.hasSuffix "/nix/browser.js" path;
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
              # /status shows it. Only this package: the dependencies and
              # the checks don't rebuild for a new commit.
              MAX_COMMIT = self.shortRev or self.dirtyShortRev or "dev";
            }
          );

          # The one-off import of the Haskell version's database; "导入" in
          # docs/rust-rewrite.md.
          max-import = craneLib.buildPackage (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoExtraArgs = "--package max-import";
              doCheck = false;
            }
          );

          # The groups' VMs boot this; nix/guest.nix. What max needs to start
          # one is a JSON file: the kernel, the initrd and the command line,
          # which max appends the VM's own parameters to.
          guest =
            let
              guest =
                (nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    microvm.nixosModules.microvm
                    ./nix/guest.nix
                    # nix shell and friends in the guest resolve nixpkgs to
                    # this pin.
                    {
                      nix.registry.nixpkgs.flake = nixpkgs;
                      nix.nixPath = [ "nixpkgs=${nixpkgs}" ];
                      _module.args.pi = inputs.llm-agents.packages.${system}.pi;
                    }
                  ];
                }).config;
            in
            pkgs.writeText "max-guest.json" (
              builtins.toJSON {
                kernel = "${guest.microvm.kernel.dev}/vmlinux";
                initrd = guest.microvm.initrdPath;
                cmdline = "earlyprintk=ttyS0 console=ttyS0 reboot=t panic=-1 ${toString guest.microvm.kernelParams}";
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
            inherit max max-import;
            default = max;
          }
          # cloud-hypervisor boots vmlinux directly only on x86_64.
          // pkgs.lib.optionalAttrs (system == "x86_64-linux") { inherit guest; };

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
                # reqwest loads the system's CA certificates when a client
                # is built, even one that only talks to a local server.
                nativeBuildInputs = [
                  (pkgs.postgresql_17.withPackages (p: [ p.pgvector ]))
                  pkgs.cacert
                  # Run the guest's runner and webread.
                  pkgs.nodejs
                  (pkgs.python3.withPackages (p: [ p.trafilatura ]))
                  pkgs.poppler-utils
                ];
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

          # These boot VMs inside the test machine, so they need KVM in it:
          # a CI runner, itself a VM, can't give it that. tank can:
          #   nix build .#nestedChecks.x86_64-linux.vm -L
          nestedChecks = pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            vm = import ./nix/tests/vm.nix {
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
      nestedChecks = forEachSystem (system: all.${system}.nestedChecks);
      devShells = forEachSystem (system: {
        default = all.${system}.devShell;
      });
    };
}
