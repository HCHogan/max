# NixOS module for the max QQ group-chat agent.
#
# Wires up everything the bot needs on one machine:
#   * a systemd service running max-bot (config rendered to YAML from
#     `settings`, secrets via `environmentFile`),
#   * a local PostgreSQL (with pgvector) and a peer-authenticated
#     database,
#   * Docker plus one-shot units that build the container images the
#     bot spawns: the nix-enabled sandbox base (max-sandbox:latest,
#     from ../sandbox-image) and the camoufox browser
#     (max-browser:latest, from ../browser-image),
#   * optionally the NapCat container (QQ client) with the outbox
#     bind-mount the file tools expect.
#
# Import via the flake:  imports = [ max.nixosModules.max-bot ];
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.max-bot;
  settingsFormat = pkgs.formats.yaml { };
  renderedConfig = settingsFormat.generate "max.yaml" cfg.settings;
  effectiveConfigFile = if cfg.configFile != null then cfg.configFile else renderedConfig;
  stateDir = "/var/lib/max-bot";
  sandboxImageSrc = ../sandbox-image;
  browserImageSrc = ../browser-image;

  # One-shot unit that builds a docker image from a store-copied build
  # context.  The tag is the context's store hash, so edits rebuild
  # exactly once and unchanged rebuilds are a no-op inspect.
  mkImageBuild = name: src: {
    description = "max: build the ${name} container image";
    after = [
      "docker.service"
      "network-online.target"
    ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.virtualisation.docker.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # First build downloads base layers and toolchains — minutes,
      # not seconds.
      TimeoutStartSec = "60min";
    };
    script = ''
      tag=$(basename ${src} | cut -c1-8)
      if ! docker image inspect "${name}:$tag" >/dev/null 2>&1; then
        docker build -t "${name}:$tag" ${src}
      fi
      # The bot's default image name tracks the current content tag.
      docker tag "${name}:$tag" ${name}:latest
    '';
  };
in
{
  options.services.max-bot = {
    enable = lib.mkEnableOption "max — QQ group-chat agent over OneBot 11";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The max-bot package to run (defaults to the flake's build).";
    };

    settings = lib.mkOption {
      inherit (settingsFormat) type;
      default = { };
      example = lib.literalExpression ''
        {
          debug = true;
          llm = {
            default = "deepseek-flash";
            profiles.deepseek-flash = {
              base_url = "https://api.deepseek.com/v1";
              model = "deepseek-v4-flash";
              # api_key comes from environmentFile (MAX_LLM_API_KEY)
            };
          };
        }
      '';
      description = ''
        Contents of max.yaml — schema per `max-bot --help` /
        max.yaml.example.  Prefer putting secrets in
        {option}`services.max-bot.environmentFile` as `MAX_*` variables
        (env beats the file in opt-env-conf's precedence), since
        `settings` ends up world-readable in the nix store.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/lib/max-bot/max.yaml";
      description = ''
        Use this max.yaml instead of rendering one from `settings`.
        For configs full of per-profile API keys (which must stay out
        of the world-readable store) point this at a root-deployed or
        sops-managed file readable by the max-bot user.  The module
        still wires db/paths via MAX_* environment variables, which
        take precedence over the file.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/max-bot.env";
      description = ''
        EnvironmentFile with secrets: MAX_LLM_API_KEY,
        MAX_ACCESS_TOKEN, MAX_TAVILY_API_KEY, ...
      '';
    };

    postgres.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Provision a local PostgreSQL database `max-bot` owned by the
        service user, reached peer-authenticated over the unix socket.
        Disable if you point db.url at an external server instead.
      '';
    };

    sandboxImage.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build the nix-enabled sandbox base image (max-sandbox:latest)
        from the repo's sandbox-image/ at boot.  The image tag is
        derived from the store hash of that directory, so changing the
        Dockerfile/nix.conf rebuilds exactly once; the shared max-nix
        store volume is seeded by docker on first container start.
      '';
    };

    browserImage.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build the camoufox browser image (max-browser:latest) from the
        repo's browser-image/ at boot, same content-tag scheme as the
        sandbox image.  The per-group browser containers the bot
        spawns are instances of this image.
      '';
    };

    napcat = {
      enable = lib.mkEnableOption "the NapCat container (QQ client) alongside the bot";

      qq = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "QQ account NapCat logs in as (0 = pick at the web UI).";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          Environment files for the container; set
          NAPCAT_ACCESS_TOKEN to the same value as the bot's
          MAX_ACCESS_TOKEN.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;

    users.users.max-bot = {
      isSystemUser = true;
      group = "max-bot";
      home = stateDir;
      # The bot drives sandboxes through the docker CLI.
      extraGroups = [ "docker" ];
    };
    users.groups.max-bot = { };

    services.postgresql = lib.mkIf cfg.postgres.enable {
      enable = true;
      extensions = ps: [ ps.pgvector ];
      ensureDatabases = [ "max-bot" ];
      ensureUsers = [
        {
          name = "max-bot";
          ensureDBOwnership = true;
        }
      ];
    };

    # The 012 migration runs CREATE EXTENSION IF NOT EXISTS vector as the
    # service user, but the nixpkgs pgvector is not marked `trusted`, so
    # only a superuser may actually create it.  Pre-create it after the
    # ensure* statements; the migration's IF NOT EXISTS then no-ops.
    # (postgresql-setup runs as the postgres superuser with psql/PGPORT
    # in its environment.)
    systemd.services.postgresql-setup.postStart = lib.mkIf cfg.postgres.enable ''
      psql -d max-bot -tAc 'CREATE EXTENSION IF NOT EXISTS vector' >/dev/null
    '';

    systemd.services.max-sandbox-image = lib.mkIf cfg.sandboxImage.enable (
      mkImageBuild "max-sandbox" sandboxImageSrc
    );
    systemd.services.max-browser-image = lib.mkIf cfg.browserImage.enable (
      mkImageBuild "max-browser" browserImageSrc
    );

    systemd.services.max-bot = {
      description = "max — QQ group-chat agent";
      after =
        [
          "network-online.target"
          "docker.service"
        ]
        ++ lib.optional cfg.postgres.enable "postgresql.service"
        ++ lib.optional cfg.sandboxImage.enable "max-sandbox-image.service"
        ++ lib.optional cfg.browserImage.enable "max-browser-image.service";
      requires =
        [ "docker.service" ]
        ++ lib.optional cfg.postgres.enable "postgresql.service"
        ++ lib.optional cfg.sandboxImage.enable "max-sandbox-image.service"
        ++ lib.optional cfg.browserImage.enable "max-browser-image.service";
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # Sandbox lifecycle shells out to the docker CLI; table replies
      # shell out to typst; sticker captioning to ffmpeg (GIF frames).
      path = [
        config.virtualisation.docker.package
        pkgs.typst
        pkgs.ffmpeg
      ];
      environment = {
        # typst needs a *static* CJK face for table rendering (the
        # nixpkgs noto CJK ships variable fonts, which typst cannot
        # render), and the service user has no fontconfig of its own.
        TYPST_FONT_PATHS = "${pkgs.source-han-sans}/share/fonts";
        # Env (not settings) so they hold for hand-managed configFile
        # setups too — opt-env-conf gives env precedence over the file.
        MAX_DB_URL = lib.mkDefault "postgresql:///max-bot?host=/run/postgresql";
        MAX_IMAGES_DIR = lib.mkDefault "${stateDir}/images";
        # The .sql files ship with the flake source, not the binary.
        MAX_MIGRATIONS_DIR = lib.mkDefault "${../migrations}";
      };
      serviceConfig = {
        User = "max-bot";
        Group = "max-bot";
        StateDirectory = "max-bot";
        # The bot resolves images_dir and var/outbox relative paths
        # against its cwd; keep everything under the state dir.
        WorkingDirectory = stateDir;
        ExecStart = "${cfg.package}/bin/max-bot --config-file ${effectiveConfigFile}";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = 5;
        # SIGTERM triggers the bot's graceful shutdown (sandbox teardown).
        TimeoutStopSec = 60;
      };
    };

    # NixOS defaults oci-containers to podman; the bot's images, the
    # max-nix volume and the host-gateway extra_host all live on the
    # docker side, so keep NapCat there too.
    virtualisation.oci-containers.backend = lib.mkIf cfg.napcat.enable "docker";

    virtualisation.oci-containers.containers.napcat = lib.mkIf cfg.napcat.enable {
      image = "mlikiowa/napcat-docker:latest";
      environment = {
        ACCOUNT = cfg.napcat.qq;
        WSR_ENABLE = "true";
        WS_URLS = ''["ws://host.docker.internal:8080/onebot"]'';
      };
      environmentFiles = cfg.napcat.environmentFiles;
      ports = [ "6099:6099" ];
      volumes = [
        "${stateDir}/napcat/QQ:/app/.config/QQ"
        "${stateDir}/napcat/config:/app/napcat/config"
        # Outbox handoff: the bot stages files at var/outbox (relative
        # to its WorkingDirectory) and references /data/outbox/... in
        # upload_group_file actions.
        "${stateDir}/var/outbox:/data/outbox"
      ];
      extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
    };

    systemd.tmpfiles.rules =
      [
        "d ${stateDir}/var/outbox 0755 max-bot max-bot -"
      ]
      ++ lib.optionals cfg.napcat.enable [
        "d ${stateDir}/napcat 0755 root root -"
        "d ${stateDir}/napcat/QQ 0755 root root -"
        "d ${stateDir}/napcat/config 0755 root root -"
      ];
  };
}
