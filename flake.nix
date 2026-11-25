{
  description = "max — a group chat agent for QQ";

  inputs = {
    # The nixpkgs revision nix-config deploys with.
    nixpkgs.url = "github:NixOS/nixpkgs/cd4ea8d57de16f4810bc5f14207bac45fbf19f67";
    # Postgres 19, which the nixpkgs above, a 26.05, hasn't: max's own
    # cluster runs it, and the dev shell's and CI's. It goes once nixpkgs
    # is a release with 19.
    nixpkgs-postgres.url = "github:NixOS/nixpkgs/619c39f6eac5d1ed6b8f073a9414baf7034b2356";
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
    # pi, the background agents, in the guest. nix/pi.sh relies on pi's
    # models.json, settings and sessions: the `pi` check says whether a
    # pin's pi keeps them (see "Background agents" in docs/design/jobs.md).
    llm-agents.url = "github:numtide/llm-agents.nix";
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
          # max's database wherever it runs, made by initdb with these.
          postgresql = inputs.nixpkgs-postgres.legacyPackages.${system}.postgresql_19;
          initdbArgs = import ./nix/initdb.nix;

          # Cargo's sources plus what the build reads besides: insta's
          # snapshots, max-db's migrations and its offline query data,
          # max-llm's recorded responses, and the guest's scripts, which
          # max's tests run with Node and Python.
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
              || (
                pkgs.lib.hasInfix "/nix/" path
                && (
                  pkgs.lib.hasSuffix ".js" path
                  || pkgs.lib.hasSuffix ".py" path
                  # The guest's own tools, which the system prompt
                  # declares too.
                  || pkgs.lib.hasSuffix ".json" path
                )
              );
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

          # The day (UTC) and the commit of the source built, as NixOS ends
          # its own versions, so every build is told apart without a tag:
          # 20261123.4999d8f. A dirty tree's commit ends in -dirty.
          version =
            let
              day = builtins.substring 0 8 (self.lastModifiedDate or "19700101");
              commit = self.shortRev or self.dirtyShortRev or "dev";
            in
            "${day}.${commit}";

          max = craneLib.buildPackage (
            commonArgs
            // {
              inherit cargoArtifacts version;
              cargoExtraArgs = "--package max-cli";
              doCheck = false; # the nextest check runs the tests
              # /status, the log and --version show it. Only this package:
              # the dependencies and the checks don't rebuild for a new
              # commit.
              MAX_VERSION = version;
            }
          );

          # What the nightly workflow runs, with the pinned cargo.
          update-pins = pkgs.writeShellApplication {
            name = "update-pins";
            runtimeInputs = [
              toolchain
              pkgs.coreutils
              pkgs.curl
              pkgs.gawk
              pkgs.git
              pkgs.jq
            ];
            # Backticks inside single quotes are the report's Markdown.
            excludeShellChecks = [ "SC2016" ];
            text = builtins.readFile ./scripts/update-pins.sh;
          };

          # The groups' VMs boot this; nix/guest.nix. What max needs to start
          # one is a JSON file: the kernel, the initrd and the command line,
          # which max appends the VM's own parameters to.
          guest = guestWith [ ];
          # With `more` modules: a test's second image.
          guestWith =
            more:
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
                  ]
                  ++ more;
                }).config;
              # cloud-hypervisor boots the ELF vmlinux on x86_64 and the Image
              # on aarch64, whose serial port is a PL011, as microvm.nix's own
              # runner has it.
              x86 = pkgs.stdenv.hostPlatform.isx86_64;
            in
            pkgs.writeText "max-guest.json" (
              builtins.toJSON {
                kernel =
                  if x86 then
                    "${guest.microvm.kernel.dev}/vmlinux"
                  else
                    "${guest.microvm.kernel.out}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
                initrd = guest.microvm.initrdPath;
                cmdline = "${
                  if x86 then "earlyprintk=ttyS0 console=ttyS0" else "console=ttyAMA0"
                } reboot=t panic=-1 ${toString guest.microvm.kernelParams}";
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
            inherit max postgresql update-pins;
            default = max;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux { inherit guest; };

          checks = {
            inherit max update-pins;

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
                  postgresql
                  pkgs.cacert
                  # Run the guest's runner and webread.
                  pkgs.nodejs
                  (pkgs.python3.withPackages (p: [ p.trafilatura ]))
                  pkgs.poppler-utils
                  pkgs.ffmpeg-headless
                ];
                # #[sqlx::test] makes a scratch database per test on this
                # server. TCP only: a socket path under $TMPDIR can be too
                # long on macOS.
                preCheck = ''
                  export PGDATA="$TMPDIR/postgres"
                  initdb --username=max --auth=trust ${pkgs.lib.escapeShellArgs initdbArgs} >/dev/null
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

            # The pinned pi keeps what nix/pi.sh rests on, against a fake
            # /llm; scripts/check-pi runs the same by hand.
            pi =
              pkgs.runCommand "check-pi"
                {
                  nativeBuildInputs = [
                    pkgs.nodejs
                    pkgs.curl
                    pkgs.jq
                  ];
                }
                ''
                  mkdir -p scripts nix
                  cp ${./scripts/check-pi.js} scripts/check-pi.js
                  cp ${./nix/pi.sh} nix/pi.sh
                  cp ${./nix/pi-system.md} nix/pi-system.md
                  node scripts/check-pi.js ${inputs.llm-agents.packages.${system}.pi}/bin/pi
                  touch $out
                '';
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            module = import ./nix/tests/module.nix {
              inherit pkgs;
              module = self.nixosModules.maxx;
            };
            # What Max runs in a guest, as units: no VM inside the test
            # machine, so this one runs wherever the module's does.
            jobs = import ./nix/tests/jobs.nix {
              inherit pkgs;
              inherit (inputs.llm-agents.packages.${system}) pi;
            };
            # The guest's image evaluates, with the pins as they are. To
            # build it is to fetch its whole closure, several GiB, and to
            # boot it takes KVM in the test's machine: tank does both, in
            # its system's build and in the nested test below.
            guest-evaluates = pkgs.writeText "guest-evaluates" (
              builtins.unsafeDiscardStringContext guest.drvPath
            );
          };

          # These boot VMs inside the test machine, so they need KVM in it:
          # a CI runner, itself a VM, can't give it that. tank can:
          #   nix build .#nestedChecks.x86_64-linux.vm -L
          # aarch64-linux has one too, for a host whose KVM nests; a Mac's
          # Linux builder's doesn't.
          nestedChecks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            vm = import ./nix/tests/vm.nix {
              # A second image, which a deploy in the test brings.
              newer = guestWith [ { environment.etc."max-image".text = "newer\n"; } ];
              inherit pkgs;
              module = self.nixosModules.maxx;
            };
          };

          devShell = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              ./devenv.nix
              {
                packages = [
                  toolchain
                  postgresql
                ];
                services.postgres = {
                  package = postgresql;
                  initdbArgs = initdbArgs;
                };
              }
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
