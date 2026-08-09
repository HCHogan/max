{
  pkgs,
  lib,
  config,
  ...
}: {
  languages.haskell = {
    enable = true;
    # Default toolchain (GHC 9.10.3 on nixpkgs 25.11): the default set
    # is hydra-cached and its HLS actually builds — 9.12.4's does not.
    package = pkgs.haskell.compiler.ghc9103;
    stack.enable = false;
    cabal = {
      enable = true;
      package = pkgs.cabal-install;
    };
    lsp = {
      enable = true;
      package = pkgs.haskell-language-server;
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

    # table replies render through the typst CLI
    typst

    # fenced code blocks render through the codesnap CLI
    codesnap

    # sticker captioning extracts a GIF frame via ffmpeg
    ffmpeg
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
    # Static CJK face for typst table rendering (matches nix/module.nix).
    TYPST_FONT_PATHS = "${pkgs.source-han-sans}/share/fonts";
    # codesnap resolves "RecMonoCasual Nerd Font Mono" through fontconfig,
    # and Recursive covers no CJK, so the alias sends the missing characters
    # to Sarasa Mono (matches nix/module.nix).  Not makeFontsConf: it appends
    # dejavu-fonts, which then wins the fallback and renders CJK as tofu.
    FONTCONFIG_FILE = pkgs.writeText "max-code-fonts.conf" ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
        <dir>${pkgs.nerd-fonts.recursive-mono}</dir>
        <dir>${pkgs.sarasa-gothic}</dir>
        <cachedir prefix="xdg">fontconfig</cachedir>
        <alias>
          <family>RecMonoCasual Nerd Font Mono</family>
          <prefer><family>Sarasa Mono SC</family></prefer>
        </alias>
      </fontconfig>
    '';
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
