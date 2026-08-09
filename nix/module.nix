# NixOS module for the max QQ group-chat agent.
#
# Wires up everything the bot needs on one machine:
#   * a systemd service running max (config rendered to YAML from
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
# The admin panel (settings.admin.port) rides inside the bot process,
# so it needs no unit of its own — but it opens a port this module does
# not touch the firewall for, deliberately: it has no TLS and one
# optional bearer token, so exposure is a decision for whoever puts a
# proxy in front.  Its token belongs in `environmentFile` as
# MAX_ADMIN_TOKEN, not in `settings` (see the warnings below).
#
# Import via the flake:  imports = [ max.nixosModules.max ];
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.max;
  settingsFormat = pkgs.formats.yaml { };
  renderedConfig = settingsFormat.generate "max.yaml" cfg.settings;
  effectiveConfigFile = if cfg.configFile != null then cfg.configFile else renderedConfig;
  # NB: the service user, its group, the database, and this directory
  # are all still spelled "max-bot" while everything you type — the
  # binary, `services.max.*`, the systemd unit, `nix build .#max` — is
  # "max".  That inconsistency is deliberate: these four are identifiers
  # bound to live state on the host, not names anyone reads.
  #
  # Renaming them is a migration, not an edit.  This directory holds the
  # NapCat QQ login state and the content-addressed blob store; the
  # database is peer-authenticated, so its role name has to match the
  # system user.  Doing it properly means stopping the bot, moving
  # /var/lib, ALTER DATABASE + ALTER ROLE, and renaming the unix user —
  # for zero benefit, since nothing outside this file refers to them.
  #
  # So: leave them.  A tidy-up that "fixes" the inconsistency logs the
  # bot out of QQ and orphans every stored image.
  stateDir = "/var/lib/max-bot";
  # How long the bot waits for in-flight agent dispatches on SIGTERM.
  # Mirrors Max.Config's default so TimeoutStopSec below can follow it.
  # Only visible when the config comes from `settings`; a hand-managed
  # `configFile` that raises the drain needs TimeoutStopSec raised too.
  drainSeconds = cfg.settings.shutdown_drain_seconds or 120;
  sandboxImageSrc = ../sandbox-image;
  browserImageSrc = ../browser-image;
  # Hand-written rather than `makeFontsConf`, which appends dejavu-fonts
  # unconditionally.  That lands DejaVu Sans *second* in the fallback
  # chain, ahead of Sarasa, and codesnap takes it — so every CJK character
  # in a snippet rendered as tofu even though a CJK font was installed and
  # fc-match found it.  Naming the fallback is the fix; relying on
  # directory order is what broke.
  codeFontsConf = pkgs.writeText "max-code-fonts.conf" ''
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

  # camoufox-js otherwise discovers and downloads the browser at image-build
  # time, then downloads uBlock Origin and a 66 MiB GeoIP database on the
  # first live session.  Besides being non-reproducible, either runtime
  # download can block launch or leave a corrupt partial cache.  Make all
  # three fixed-output Nix inputs and let Docker only unpack local bytes.
  camoufoxBrowser = import ./camoufox-browser.nix { inherit pkgs; };
  camoufoxBrowserArchive = camoufoxBrowser.archive;
  camoufoxBrowserArchiveName = baseNameOf "${camoufoxBrowserArchive}";
  camoufoxBrowserArchiveDir = dirOf "${camoufoxBrowserArchive}";
  camoufoxUblockOrigin = camoufoxBrowser.ublockOrigin;
  camoufoxUblockOriginName = baseNameOf "${camoufoxUblockOrigin}";
  camoufoxUblockOriginDir = dirOf "${camoufoxUblockOrigin}";
  camoufoxGeoLiteCity = camoufoxBrowser.geoLiteCity;
  camoufoxGeoLiteCityName = baseNameOf "${camoufoxGeoLiteCity}";
  camoufoxGeoLiteCityDir = dirOf "${camoufoxGeoLiteCity}";

  # The ordinary directory store path only changes with browser-image/.
  # Include the fixed-output browser path in a separate fingerprint so a
  # browser bump necessarily produces a fresh docker tag as well.
  browserImageFingerprint = pkgs.writeText "max-browser-image-inputs" ''
    docker-context=${browserImageSrc}
    camoufox-browser=${camoufoxBrowserArchive}
    ublock-origin=${camoufoxUblockOrigin}
    geolite-city=${camoufoxGeoLiteCity}
  '';

  # One-shot unit that builds a docker image from store-backed inputs.
  # The tag is the input fingerprint's store hash, so edits rebuild exactly
  # once and unchanged rebuilds are a no-op inspect.
  mkImageBuild =
    {
      name,
      src,
      tagSource ? src,
      buildCommand ? ''docker build -t "${name}:$tag" ${src}'',
    }:
    {
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
        set -o pipefail
        tag=$(basename ${tagSource} | cut -c1-8)
        if ! docker image inspect "${name}:$tag" >/dev/null 2>&1; then
          ${buildCommand}
        fi
        # The bot's default image name tracks the current content tag.
        docker tag "${name}:$tag" ${name}:latest
      '';
    };
in
{
  options.services.max = {
    enable = lib.mkEnableOption "max — QQ group-chat agent over OneBot 11";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The max package to run (defaults to the flake's build).";
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
        Contents of max.yaml — schema per `max --help` /
        max.yaml.example.  Prefer putting secrets in
        {option}`services.max.environmentFile` as `MAX_*` variables
        (env beats the file in opt-env-conf's precedence), since
        `settings` ends up world-readable in the nix store.

        Ignored entirely when {option}`services.max.configFile` is set —
        the two are alternatives, not layers.  A `MAX_*` variable is the
        way to add one key on top of a hand-managed file.
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
        sops-managed file readable by the max-bot user.

        Setting this discards {option}`services.max.settings` — the
        module warns rather than merging, because merging a store-
        rendered file with a hand-managed one has no sane answer.  To
        override a single key, set its `MAX_*` variable: the module
        already wires db/paths that way, and env beats the file.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/max.env";
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
        Fetch and verify the pinned Camoufox browser with Nix, then build
        max-browser:latest from the repo's browser-image/ at boot.  The
        image tag fingerprints both inputs, so an unchanged rebuild is a
        no-op.  The per-group browser containers the bot spawns are
        instances of this image.
      '';
    };

    wechatpad = {
      enable = lib.mkEnableOption ''
        the WeChatPadPro relay stack (WeChat via the reverse-engineered
        iPad protocol — ban risk is yours; run a spare account).
        Serves the API on port 8848 (container 8080) and the login web
        UI on 1238; point the bot's wechatpad.api_url at
        http://127.0.0.1:8848
      '';

      adminKey = lib.mkOption {
        type = lib.types.str;
        default = "changeme-wechatpad-admin";
        description = ''
          WeChatPadPro ADMIN_KEY (also the API auth key the bot's
          wechatpad.auth_key must match).  Lands in the nix store —
          fine for a LAN-only home box, change it from the default
          regardless.
        '';
      };

      mysqlPassword = lib.mkOption {
        type = lib.types.str;
        default = "weixin123";
        description = "Password for the stack-internal MySQL (never exposed beyond the docker network).";
      };

      webBindAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        example = "100.64.0.3";
        description = ''
          Address the login web UI (port 1238) binds to.  Loopback by
          default; set your tailscale IP to reach it from the tailnet.
          NB: docker-published ports bypass the NixOS firewall, so
          bind to a specific interface address rather than 0.0.0.0.
          The API port (8848) always stays on loopback — the bot runs
          on this host.
        '';
      };
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
    # `configFile` wins outright, so anything in `settings` is silently
    # discarded — which reads as "I set that and it didn't work".  Say
    # so, and point at the channel that does work with a hand-managed
    # file: MAX_* environment variables, which beat the file either way.
    warnings =
      lib.optional (cfg.configFile != null && cfg.settings != { }) ''
        services.max: `settings` is ignored because `configFile` is set
        (${toString cfg.configFile}). Move these keys into that file, or
        set them as MAX_* variables via
        `systemd.services.max.environment` / `services.max.environmentFile`:
        ${lib.concatStringsSep ", " (lib.attrNames cfg.settings)}
      ''
      # The rendered max.yaml lands in the world-readable nix store, so a
      # token written here is a token every local user can read.  It is
      # the panel's only credential, hence its own warning rather than a
      # line in the docs nobody reads twice.
      ++ lib.optional ((cfg.settings.admin.token or null) != null) ''
        services.max: `settings.admin.token` ends up world-readable in the
        nix store. Put it in `services.max.environmentFile` as
        MAX_ADMIN_TOKEN instead (env beats the file) and drop the key here.
      ''
      # Loopback is the deployment story: the panel serves no TLS and
      # authenticates with at most one bearer token, so anything reachable
      # from off-box wants a proxy in front doing both.  A specific
      # LAN/tailnet address is a deliberate choice; 0.0.0.0 usually isn't.
      ++ lib.optional ((cfg.settings.admin.host or "127.0.0.1") == "0.0.0.0") ''
        services.max: `settings.admin.host` is 0.0.0.0, so the admin panel
        answers on every interface. It has no TLS and no users — put a
        reverse proxy in front, or bind one address (a tailnet IP,
        127.0.0.1) instead.
      '';

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
      mkImageBuild {
        name = "max-sandbox";
        src = sandboxImageSrc;
      }
    );
    systemd.services.max-browser-image = lib.mkIf cfg.browserImage.enable (
      mkImageBuild {
        name = "max-browser";
        src = browserImageSrc;
        tagSource = browserImageFingerprint;
        # Stream the runtime assets into the context instead of copying
        # another ~730 MiB into a context derivation in the Nix store.
        # Docker still receives a normal tar context, entirely local.
        buildCommand = ''
          ${pkgs.gnutar}/bin/tar \
            --create --file=- \
            --transform='s|^${camoufoxBrowserArchiveName}$|camoufox-browser.zip|' \
            --transform='s|^${camoufoxUblockOriginName}$|ublock-origin.xpi|' \
            --transform='s|^${camoufoxGeoLiteCityName}$|GeoLite2-City.mmdb|' \
            --directory=${browserImageSrc} . \
            --directory=${camoufoxBrowserArchiveDir} ${camoufoxBrowserArchiveName} \
            --directory=${camoufoxUblockOriginDir} ${camoufoxUblockOriginName} \
            --directory=${camoufoxGeoLiteCityDir} ${camoufoxGeoLiteCityName} \
            | docker build \
                --build-arg CAMOUFOX_BROWSER_VERSION=${camoufoxBrowser.version} \
                --build-arg CAMOUFOX_BROWSER_RELEASE=${camoufoxBrowser.release} \
                -t "max-browser:$tag" -
        '';
      }
    );

    systemd.services.max = {
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
      # shell out to typst and code blocks to codesnap; sticker captioning
      # to ffmpeg (GIF frames).
      path = [
        config.virtualisation.docker.package
        pkgs.typst
        pkgs.codesnap
        pkgs.ffmpeg
      ];
      environment = {
        # typst needs a *static* CJK face for table rendering (the
        # nixpkgs noto CJK ships variable fonts, which typst cannot
        # render), and the service user has no fontconfig of its own.
        TYPST_FONT_PATHS = "${pkgs.source-han-sans}/share/fonts";
        # codesnap goes through fontconfig rather than an env var, and
        # finds nothing without one: the sandbox gives this user no home
        # and no system font path.  Both faces are load-bearing —
        # Max.Render asks for RecMonoCasual by name, and Recursive covers
        # no CJK, so Sarasa Mono is what the alias sends the missing
        # characters to.
        FONTCONFIG_FILE = codeFontsConf;
        # codesnap writes a default config under $HOME on every run and
        # panics on the unwrap if it cannot (`--config` does not avoid
        # this).  The sandbox below would otherwise leave HOME unwritable
        # and every code block would fail to render.
        HOME = stateDir;
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
        ExecStart = "${cfg.package}/bin/max --config-file ${effectiveConfigFile}";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = 5;
        # SIGTERM starts the bot's graceful drain: no new agent
        # dispatches, finish the running ones, then tear down sandboxes
        # and the DB pool.  Systemd has to outwait that, or it SIGKILLs
        # mid-drain and the waiting bought nothing.
        TimeoutStopSec = drainSeconds + 30;

        # Sandboxing.  The whole of what this process needs from the host
        # is: TCP in (WS endpoint, admin panel) and out (LLM APIs, web
        # tools), two unix sockets (/run/postgresql, /run/docker.sock),
        # its own state directory, and a writable /tmp for the typst and
        # ffmpeg workspaces.  Everything below takes away something it
        # never asked for.
        #
        # Read this before adding more: the service user is in the
        # `docker` group, and the docker socket is root on this host by
        # construction.  These settings shrink the blast radius of a bug;
        # they do not contain an attacker who knows the socket is there.
        # The fix for *that* is rootless docker or a socket proxy, not a
        # longer list here.
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
        # Both listeners are unprivileged ports, so no capability is
        # needed to bind them.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateMounts = true;
        ProtectProc = "invisible";
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        SystemCallErrorNumber = "EPERM";
        # Maps every uid but this one to nobody.  Verified against the
        # two things that could plausibly break: the docker socket still
        # opens through the `docker` supplementary group, and postgres
        # peer auth still sees max-bot rather than an overflow uid.  If
        # something ever behaves strangely under this unit, drop this
        # line first — it is the only setting here that adds a namespace
        # rather than removing an ability.
        PrivateUsers = true;
        # AF_NETLINK is kept, but not because DNS dies without it —
        # measured, glibc falls back to assuming both families work.
        # What it loses is getaddrinfo's address sorting, so a
        # dual-stack endpoint can get tried in the useless order first.
        # 0.1 of exposure is not worth that class of intermittent
        # timeout.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        # Blobs, staged outbox files and rendered tables are the bot's
        # own; nothing on this host reads them as another user.  NapCat
        # reads the outbox as container root through the bind mount,
        # which 0600 does not stop.
        UMask = "0077";
        # Left off on purpose, each for a reason that outlives the next
        # `systemd-analyze security` run:
        #   PrivateNetwork  — the bot *is* a network service.
        #   IPAddressDeny   — LLM APIs, web search and the browser tool
        #                     reach arbitrary hosts; there is no list.
        #   ProcSubset=pid  — hides /proc/uptime, which the status
        #                     command reads for host uptime (measured:
        #                     ENOENT, not a permission error, so the
        #                     uptime silently reads as unknown).
        #   MemoryDenyWriteExecute — GHC's adjustors want RWX pages the
        #                     moment any dependency takes a `foreign
        #                     import "wrapper"` callback.  Worth 0.1,
        #                     costs an RTS abort at an unpredictable
        #                     hour; enable only behind a soak test.
      };
    };

    # NixOS defaults oci-containers to podman; the bot's images, the
    # max-nix volume and the host-gateway extra_host all live on the
    # docker side, so keep NapCat/WeChatPadPro there too.
    virtualisation.oci-containers.backend =
      lib.mkIf (cfg.napcat.enable || cfg.wechatpad.enable) "docker";

    # WeChatPadPro stack: app + its private MySQL/Redis on an isolated
    # bridge network (mirrors upstream deploy/docker-compose.yml).
    # The app reads /app/.env, so we generate one from the options and
    # mount it — same dual env-file + environment channel as upstream.
    systemd.services.init-wechatpad-network = lib.mkIf cfg.wechatpad.enable {
      description = "Create the wechatpad docker network";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      path = [ config.virtualisation.docker.package ];
      script = ''
        docker network inspect wechatpad >/dev/null 2>&1 \
          || docker network create wechatpad
      '';
    };

    virtualisation.oci-containers.containers = lib.mkMerge [
      (lib.mkIf cfg.wechatpad.enable {
        wechatpad-mysql = {
          image = "mysql:8.0";
          environment = {
            MYSQL_ROOT_PASSWORD = cfg.wechatpad.mysqlPassword;
            MYSQL_DATABASE = "weixin";
            MYSQL_USER = "weixin";
            MYSQL_PASSWORD = cfg.wechatpad.mysqlPassword;
          };
          volumes = [ "${stateDir}/wechatpad/mysql:/var/lib/mysql" ];
          extraOptions = [ "--network=wechatpad" ];
        };

        wechatpad-redis = {
          image = "redis:6";
          cmd = [ "redis-server" "--appendonly" "yes" ];
          volumes = [ "${stateDir}/wechatpad/redis:/data" ];
          extraOptions = [ "--network=wechatpad" ];
        };

        wechatpad =
          let
            envFile = pkgs.writeText "wechatpad.env" ''
              WECHAT_PORT=8080
              PORT=1238
              TZ=Asia/Shanghai
              ADMIN_KEY=${cfg.wechatpad.adminKey}
              WORKER_POOL_SIZE=500
              MAX_WORKER_TASK_LEN=1000
              WEB_DOMAIN=localhost:1238
              NEWS_SYN_WXID=true
              DT=true
              TOPIC=wx_sync_msg_topic
              ROCKET_MQ_ENABLED=false
              RABBIT_MQ_ENABLED=false
              KAFKA_ENABLED=false
              DB_HOST=wechatpad-mysql
              DB_PORT=3306
              DB_DATABASE=weixin
              DB_USERNAME=weixin
              DB_PASSWORD=${cfg.wechatpad.mysqlPassword}
              MYSQL_CONNECT_STR=weixin:${cfg.wechatpad.mysqlPassword}@tcp(wechatpad-mysql:3306)/weixin?charset=utf8mb4&parseTime=true&loc=Local
              REDIS_HOST=wechatpad-redis
              REDIS_PORT=6379
              REDIS_DB=0
            '';
          in
          {
            image = "wechatpadpro/wechatpadpro:latest";
            environment = {
              DB_HOST = "wechatpad-mysql";
              REDIS_HOST = "wechatpad-redis";
              ADMIN_KEY = cfg.wechatpad.adminKey;
              TZ = "Asia/Shanghai";
              MYSQL_CONNECT_STR = "weixin:${cfg.wechatpad.mysqlPassword}@tcp(wechatpad-mysql:3306)/weixin?charset=utf8mb4&parseTime=true&loc=Local";
            };
            # Bot's own WS server owns host 8080 → API rides on 8848.
            ports = [
              "127.0.0.1:8848:8080"
              "${cfg.wechatpad.webBindAddress}:1238:1238"
            ];
            volumes = [ "${envFile}:/app/.env" ];
            dependsOn = [ "wechatpad-mysql" "wechatpad-redis" ];
            extraOptions = [ "--network=wechatpad" ];
          };
      })
      (lib.mkIf cfg.napcat.enable {
        napcat = {
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
      })
    ];

    systemd.tmpfiles.rules =
      [
        "d ${stateDir}/var/outbox 0755 max-bot max-bot -"
      ]
      ++ lib.optionals cfg.napcat.enable [
        "d ${stateDir}/napcat 0755 root root -"
        "d ${stateDir}/napcat/QQ 0755 root root -"
        "d ${stateDir}/napcat/config 0755 root root -"
      ]
      ++ lib.optionals cfg.wechatpad.enable [
        "d ${stateDir}/wechatpad 0755 root root -"
        "d ${stateDir}/wechatpad/mysql 0755 root root -"
        "d ${stateDir}/wechatpad/redis 0755 root root -"
      ];
  };
}
