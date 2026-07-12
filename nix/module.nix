# NixOS module for the max QQ group-chat agent.
#
# Wires up everything the bot needs on one machine:
#   * a systemd service running max-bot (config rendered to YAML from
#     `settings`, secrets via `environmentFile`),
#   * a local PostgreSQL with a peer-authenticated database,
#   * Docker plus a one-shot unit that builds the nix-enabled sandbox
#     base image (max-sandbox:latest) from ../sandbox-image,
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
  configFile = settingsFormat.generate "max.yaml" cfg.settings;
  stateDir = "/var/lib/max-bot";
  sandboxImageSrc = ../sandbox-image;
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
    services.max-bot.settings = {
      db.url = lib.mkDefault "postgresql:///max-bot?host=/run/postgresql";
      images_dir = lib.mkDefault "${stateDir}/images";
      # The .sql files ship with the flake source, not the binary.
      migrations_dir = lib.mkDefault "${../migrations}";
    };

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
      ensureDatabases = [ "max-bot" ];
      ensureUsers = [
        {
          name = "max-bot";
          ensureDBOwnership = true;
        }
      ];
    };

    systemd.services.max-sandbox-image = lib.mkIf cfg.sandboxImage.enable {
      description = "max: build the nix-enabled sandbox base image";
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
        # First build pins nixpkgs and pre-warms the eval cache —
        # minutes of downloads, not seconds.
        TimeoutStartSec = "45min";
      };
      script = ''
        tag=$(basename ${sandboxImageSrc} | cut -c1-8)
        if ! docker image inspect "max-sandbox:$tag" >/dev/null 2>&1; then
          docker build -t "max-sandbox:$tag" ${sandboxImageSrc}
        fi
        # The bot's default image name tracks the current content tag.
        docker tag "max-sandbox:$tag" max-sandbox:latest
      '';
    };

    systemd.services.max-bot = {
      description = "max — QQ group-chat agent";
      after =
        [
          "network-online.target"
          "docker.service"
        ]
        ++ lib.optional cfg.postgres.enable "postgresql.service"
        ++ lib.optional cfg.sandboxImage.enable "max-sandbox-image.service";
      requires =
        [ "docker.service" ]
        ++ lib.optional cfg.postgres.enable "postgresql.service"
        ++ lib.optional cfg.sandboxImage.enable "max-sandbox-image.service";
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # Sandbox lifecycle shells out to the docker CLI.
      path = [ config.virtualisation.docker.package ];
      serviceConfig = {
        User = "max-bot";
        Group = "max-bot";
        StateDirectory = "max-bot";
        # The bot resolves images_dir and var/outbox relative paths
        # against its cwd; keep everything under the state dir.
        WorkingDirectory = stateDir;
        ExecStart = "${cfg.package}/bin/max-bot --config-file ${configFile}";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = 5;
        # SIGTERM triggers the bot's graceful shutdown (sandbox teardown).
        TimeoutStopSec = 60;
      };
    };

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
