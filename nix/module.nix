# NixOS module for the max QQ group-chat agent.
#
# Wires up everything the bot needs on one machine:
#   * a systemd service running max (config rendered to YAML from
#     `settings`, secrets via `environmentFile`),
#   * a local PostgreSQL (with pgvector) and a peer-authenticated
#     database,
#   * the Haskell runtime broker, native browser service templates and
#     dynamically launched NixOS sandboxes under max-stack.target,
#   * optionally native NapCat with the outbox bind mount the file tools expect.
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
  # Hand-written rather than `makeFontsConf`, which appends dejavu-fonts
  # unconditionally.  That lands DejaVu Sans *second* in the fallback
  # chain, ahead of Sarasa, and codesnap takes it — so every CJK character
  # in a snippet rendered as tofu even though a CJK font was installed and
  # fc-match found it.  Naming the fallback is the fix; relying on
  # directory order is what broke.
  # The ocean palette, and the config that makes codesnap able to find it.
  # A .tmTheme is only resolvable when the config names the folder holding
  # it (`themes_folders`); there is no CLI flag for that, which is why the
  # rest of the appearance lives here too rather than split across flags.
  codeThemes = pkgs.runCommand "max-code-themes" { } ''
    mkdir -p $out
    cp ${../assets/codesnap}/*.tmTheme $out/
  '';
  # Every nested field is spelled out even where the value is codesnap's own
  # default: its deserializer rejects a partial object rather than filling
  # gaps in, so an override-only config fails with `missing field`.
  codeFontFamily = "RecMonoCasual Nerd Font Mono";
  codeSnapConfig = pkgs.writeText "max-codesnap.json" (
    builtins.toJSON {
      print_eggs = false;
      snapshot_config = {
        theme = "ocean";
        themes_folders = [ "${codeThemes}" ];
        code_config = {
          font_family = codeFontFamily;
          breadcrumbs = {
            enable = false;
            separator = "/";
            color = "#80848b";
            font_family = codeFontFamily;
          };
        };
        # Decoration on something being read on a phone.  The shadow is killed
        # by colour, not by radius: radius 0 removes the blur and leaves the
        # default #00000040 as a hard-edged block the width of the window.
        watermark = {
          content = "";
          font_family = codeFontFamily;
          color = "#ffffff";
        };
        window = {
          mac_window_bar = false;
          margin = {
            x = 16;
            y = 16;
          };
          shadow = {
            radius = 0;
            color = "#00000000";
          };
          radius = 12;
          border = {
            width = 1;
            color = "#ffffff18";
          };
          title_config = {
            color = "#ffffff";
            font_family = codeFontFamily;
          };
        };
        # Silver-blue, left to right: pale enough that the dark window keeps a
        # visible edge against it in a chat thumbnail.
        background = {
          start = {
            x = 0;
            y = 0;
          };
          end = {
            x = "max";
            y = 0;
          };
          stops = [
            {
              position = 0;
              color = "#cfdce8";
            }
            {
              position = 1;
              color = "#f2f7fa";
            }
          ];
        };
      };
    }
  );
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

in
{
  imports = [
    ./runtime.nix
    ./sandbox-network.nix
    ./napcat-module.nix
  ];
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

    maxops = {
      enable = lib.mkEnableOption "maxops fleet tools scoped by the hub principal's capabilities";
      baseUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:9721";
        description = "Authenticated maxops hub URL, without embedded credentials.";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Runtime token file for a dedicated maxops client, loaded through systemd credentials.";
      };
      allowedGroups = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.ints.positive);
        default = null;
        example = [ 611798505 ];
        description = "QQ group allowlist. Null leaves max.yaml maxops.allowed_groups in control; an empty list denies everyone. Explicit lists override YAML.";
      };
    };

    maxopsNotifications = {
      enable = lib.mkEnableOption "authenticated loopback fleet notifications into the durable outbox";
      port = lib.mkOption {
        type = lib.types.port;
        default = 9722;
        description = "Loopback-only notification receiver port.";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Dedicated incoming notification credential, supplied through LoadCredential.";
      };
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.ints.positive;
        default = [ ];
        description = "Fixed target QQ groups; webhook bodies cannot select destinations.";
      };
      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Inventory host names whose alerts may be delivered.";
      };
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

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !cfg.maxops.enable
          || (lib.hasPrefix "/" cfg.maxops.tokenFile && !lib.hasPrefix "/nix/store/" cfg.maxops.tokenFile);
        message = "services.max.maxops.tokenFile must be an absolute runtime path outside the Nix store.";
      }
      {
        assertion =
          !cfg.maxopsNotifications.enable
          || (
            lib.hasPrefix "/" cfg.maxopsNotifications.tokenFile
            && !lib.hasPrefix "/nix/store/" cfg.maxopsNotifications.tokenFile
            && cfg.maxopsNotifications.groups != [ ]
            && cfg.maxopsNotifications.hosts != [ ]
          );
        message = "services.max.maxopsNotifications requires a runtime credential and explicit nonempty groups and hosts.";
      }
    ];
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

    users.users.max-bot = {
      isSystemUser = true;
      group = "max-bot";
      home = stateDir;
      extraGroups = [ "max-outbox" ];
    };
    users.groups.max-bot = { };
    users.groups.max-outbox = { };

    # The process always re-reads this stable name. For rendered/Nix-owned
    # configuration, activation updates the symlink before systemd invokes the
    # reload trigger; package and unit changes still alter ExecStart and cause
    # a restart.
    environment.etc."max/config.yaml".source = effectiveConfigFile;

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

    systemd.services.max = {
      description = "max — QQ group-chat agent";
      reloadTriggers = [ effectiveConfigFile ];
      after = [ "network-online.target" ] ++ lib.optional cfg.postgres.enable "postgresql.service";
      requires = lib.optional cfg.postgres.enable "postgresql.service";
      wants = [ "network-online.target" ];
      wantedBy = [ "max-stack.target" ];
      # Table rendering, code screenshots and animated-sticker frames.
      path = [
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
        # Appearance and the ocean theme registration; Max.Render passes this
        # to codesnap as --config.  Unset would still render, just with
        # codesnap's own defaults.
        MAX_CODESNAP_CONFIG = codeSnapConfig;
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
      }
      // lib.optionalAttrs cfg.maxops.enable (
        {
          MAX_MAXOPS_ENABLED = "True";
          MAX_MAXOPS_BASE_URL = cfg.maxops.baseUrl;
          MAX_MAXOPS_TOKEN_FILE = "/run/credentials/max.service/maxops-token";
        }
        // lib.optionalAttrs (cfg.maxops.allowedGroups != null) {
          MAX_MAXOPS_ALLOWED_GROUPS = lib.concatMapStringsSep "," toString cfg.maxops.allowedGroups;
        }
      )
      // lib.optionalAttrs cfg.maxopsNotifications.enable {
        MAX_MAXOPS_NOTIFY_PORT = toString cfg.maxopsNotifications.port;
        MAX_MAXOPS_NOTIFY_HOST = "127.0.0.1";
        MAX_MAXOPS_NOTIFY_TOKEN_FILE = "/run/credentials/max.service/maxops-notifications";
        MAX_MAXOPS_NOTIFY_GROUPS = lib.concatMapStringsSep "," toString cfg.maxopsNotifications.groups;
        MAX_MAXOPS_NOTIFY_HOSTS = lib.concatStringsSep "," cfg.maxopsNotifications.hosts;
      };
      serviceConfig = {
        User = "max-bot";
        Group = "max-bot";
        StateDirectory = "max-bot";
        RuntimeDirectory = "max";
        # The bot resolves images_dir and var/outbox relative paths
        # against its cwd; keep everything under the state dir.
        WorkingDirectory = stateDir;
        ExecStart = "${cfg.package}/bin/max --config-file /etc/max/config.yaml";
        ExecReload = "${cfg.package}/bin/maxctl reload --socket /run/max/control.sock";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        LoadCredential =
          lib.optional cfg.maxops.enable "maxops-token:${cfg.maxops.tokenFile}"
          ++ lib.optional cfg.maxopsNotifications.enable "maxops-notifications:${cfg.maxopsNotifications.tokenFile}";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = 30;
        # SIGTERM starts the bot's graceful drain: no new agent
        # dispatches, finish the running ones, then tear down sandboxes
        # and the DB pool.  Systemd has to outwait that, or it SIGKILLs
        # mid-drain and the waiting bought nothing.
        TimeoutStopSec = drainSeconds + 30;

        # Sandboxing.  The whole of what this process needs from the host
        # is: TCP in (WS endpoint, admin panel) and out (LLM APIs, web
        # tools), unix sockets for PostgreSQL and the restricted runtime broker,
        # its own state directory, and a writable /tmp for the typst and
        # ffmpeg workspaces.  Everything below takes away something it
        # never asked for.
        #
        # The runtime broker is a separate root process with a fixed API.
        # Max has no Docker group membership or general host command authority.
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
        # Preserve the service uid for PostgreSQL peer auth and broker
        # SO_PEERCRED authorization while mapping unrelated users to nobody.
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
        # Private by default. Delivery explicitly grants the dedicated
        # outbox group read access to short-lived QQ upload files.
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

    systemd.tmpfiles.rules = [
      "d ${stateDir}/var/outbox 2770 max-bot max-outbox -"
    ];
  };
}
