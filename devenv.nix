{
  pkgs,
  lib,
  config,
  ...
}: {
  languages.haskell = {
    enable = true;
    package = pkgs.haskell.compiler.ghc9122;
    stack.enable = false;
    cabal = {
      enable = true;
      package = pkgs.cabal-install;
    };
    lsp = {
      enable = true;
      package = pkgs.haskell.packages.ghc9122.haskell-language-server;
    };
  };

  packages = with pkgs; [
    hpack
    ormolu
    hlint

    # tooling for protocol debugging
    websocat
    jq

    # postgres client
    postgresql_17
  ];

  services.postgres = {
    enable = true;
    package = pkgs.postgresql_17;
    extensions = exts: [exts.pgvector];
    listen_addresses = "127.0.0.1";
    port = 5433;
    initialDatabases = [
      {name = "max";}
    ];
    initialScript = ''
      CREATE EXTENSION IF NOT EXISTS vector;
    '';
  };

  env = {
    MAX_DB_URL = "postgresql://127.0.0.1:5433/max";
    MAX_WS_HOST = "0.0.0.0";
    MAX_WS_PORT = "8080";
    MAX_WS_PATH = "/onebot";
    # set MAX_ACCESS_TOKEN in .env (gitignored); keep it identical to NapCat config
  };

  # Note: devenv's built-in `dotenv.enable` resolves the path through
  # Nix's flake-eval view of the source, which silently misses any
  # gitignored .env. Source it ourselves so the file is read from the
  # actual working tree at shell-entry time.
  enterShell = ''
    if [ -f "$DEVENV_ROOT/.env" ]; then
      set -a
      . "$DEVENV_ROOT/.env"
      set +a
    fi
    echo "max devshell ready — GHC $(ghc --version | awk '{print $NF}')"
    echo "  postgres: $MAX_DB_URL"
    echo "  ws:       ws://$MAX_WS_HOST:$MAX_WS_PORT$MAX_WS_PATH"
    if [ -z "''${MAX_ACCESS_TOKEN:-}" ]; then
      echo "  warning: MAX_ACCESS_TOKEN not set (put it in .env)"
    fi
    if [ -z "''${MAX_LLM_API_KEY:-}" ]; then
      echo "  warning: MAX_LLM_API_KEY not set (put it in .env)"
    fi
  '';
}
