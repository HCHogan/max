{ pkgs, ... }:
{
  # The Rust toolchain comes from the flake, which reads rust-toolchain.toml.
  packages = with pkgs; [
    cargo-deny
    cargo-machete
    cargo-nextest
    sqlx-cli
    # max's tests run the guest's runner and webread.
    nodejs
    (python3.withPackages (p: [ p.trafilatura ]))
    poppler-utils
    ffmpeg-headless
  ];

  # `devenv up` starts it. The Haskell checkout's shell uses 5433, so the two
  # can run side by side. Its package and initdb's arguments are set in
  # flake.nix, as CI's are.
  services.postgres = {
    enable = true;
    listen_addresses = "127.0.0.1";
    port = 5434;
    initialDatabases = [ { name = "max"; } ];
    # A role of our own, so the URL doesn't depend on who ran initdb.
    initialScript = "create role max login superuser;";
  };

  # sqlx's macros check queries against this database, and #[sqlx::test]
  # creates a scratch database per test on the same server.
  env.DATABASE_URL = "postgresql://max@127.0.0.1:5434/max";
}
