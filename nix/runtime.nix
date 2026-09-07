{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.max;
  runtime = cfg.runtime;
  instancePolicy =
    kind:
    pkgs.writeText "max-${kind}-policy" (
      builtins.toJSON (
        {
          service = config.systemd.services."max-${kind}@".serviceConfig;
          environment = config.systemd.services."max-${kind}@".environment;
        }
        // lib.optionalAttrs (kind == "sandbox") {
          nixpkgs = toString cfg.sandbox.nixpkgs;
          dns = cfg.sandbox.nameservers;
          network =
            if cfg.sandboxNetwork.enable then config.networking.nftables.tables.max-sandbox.content else null;
        }
      )
    );
  brokerConfig = pkgs.writeText "max-runtime.json" (
    builtins.toJSON {
      user = "max-bot";
      stateDirectory = runtime.stateDirectory;
      gcRootsDirectory = "/nix/var/nix/gcroots/max-sandboxes";
      legacyVolumeDirectory = "/var/lib/docker/volumes";
      nixpkgs = toString cfg.sandbox.nixpkgs;
      system = pkgs.stdenv.hostPlatform.system;
      bridge = "max-sb-native";
      subnet = "10.231.0.0/16";
      gateway = "10.231.0.1";
      dns = cfg.sandbox.nameservers;
      # Each backend adopts only its own effective template. A browser package
      # change must not invalidate unrelated, running command sandboxes.
      generations =
        lib.optionalAttrs cfg.sandbox.enable { sandbox = instancePolicy "sandbox"; }
        // lib.optionalAttrs cfg.browser.enable { browser = instancePolicy "browser"; };
      commands = {
        systemctl = "${config.systemd.package}/bin/systemctl";
        systemd-run = "${config.systemd.package}/bin/systemd-run";
        ip = "${pkgs.iproute2}/bin/ip";
        bridge = "${pkgs.iproute2}/bin/bridge";
        nix = "${pkgs.nix}/bin/nix";
      };
    }
  );
  client = cfg.package;
  guestInit = pkgs.writeScript "max-sandbox-init" ''
    #!${pkgs.runtimeShell} -e
    trap 'exit 0' SIGRTMIN+3
    umask 0022
    set +e
    source ${cfg.sandbox.package}/init
  '';
in
{
  options.services.max = {
    runtime.stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/max-runtime";
      description = "Root-owned instance metadata and durable sandbox work directories.";
    };
    sandbox = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable native NixOS command sandboxes.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        description = "Prebuilt container-mode NixOS system closure.";
      };
      extraModules = lib.mkOption {
        type = lib.types.listOf lib.types.deferredModule;
        default = [ ];
        description = "Additional NixOS modules used to build the shared sandbox guest system.";
      };
      nixpkgs = lib.mkOption {
        type = lib.types.path;
        description = "Pinned source used for guest packages and host package preparation.";
      };
      nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "223.5.5.5"
          "119.29.29.29"
        ];
        description = "Public DNS servers reachable through the sandbox egress policy.";
      };
    };
    browser = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable native browser service instances.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        description = "Pinned native Camoufox MCP runtime.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    boot.enableContainers = lib.mkIf cfg.sandbox.enable true;
    systemd.targets.max-stack = {
      description = "Max application stack";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "max.service"
        "max-runtime.socket"
      ]
      ++ lib.optional cfg.napcat.enable "max-napcat.service";
    };
    systemd.slices.max = {
      description = "Max application resources";
    };
    systemd.slices.max-sandbox = {
      description = "Max command sandboxes";
    };
    systemd.slices.max-browser = {
      description = "Max browser instances";
    };

    environment.systemPackages = [ client ];
    systemd.tmpfiles.rules = [
      "d ${runtime.stateDirectory} 0700 root root -"
      "d /run/netns 0755 root root -"
      "d /nix/var/nix/gcroots/max-sandboxes 0700 root root -"
    ];
    systemd.sockets.max-runtime = {
      description = "Max instance control socket";
      partOf = [ "max-stack.target" ];
      socketConfig = {
        ListenStream = "/run/max-runtime/control.sock";
        SocketUser = "max-bot";
        SocketGroup = "max-bot";
        SocketMode = "0600";
        DirectoryMode = "0755";
        RemoveOnStop = true;
      };
    };
    systemd.services.max-runtime = {
      description = "Max restricted instance broker";
      partOf = [ "max-stack.target" ];
      requires = [ "max-runtime.socket" ];
      after = [ "max-runtime.socket" ] ++ lib.optional cfg.sandbox.enable "max-sandbox-network.service";
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/max-runtime --serve ${brokerConfig}";
        User = "root";
        Slice = "max.slice";
        Restart = "on-failure";
        NoNewPrivileges = true;
        UMask = "0077";
        MemoryMax = "3G";
        TasksMax = 1024;
        # Named network namespaces must be mounted in the host mount namespace.
        PrivateMounts = false;
        PrivateTmp = false;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
      };
    };

    systemd.services."max-sandbox@" = lib.mkIf cfg.sandbox.enable {
      description = "Max NixOS sandbox %i";
      partOf = [ "max-stack.target" ];
      requires = [ "max-sandbox-network.service" ];
      after = [ "max-sandbox-network.service" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        Delegate = true;
        Slice = "max-sandbox.slice";
        # Join before nspawn creates its user namespace. A later setns into a
        # host-owned netns would fail after losing capabilities in the parent.
        NetworkNamespacePath = "/run/netns/max-sb-%i";
        ExecStart = lib.concatStringsSep " " [
          "${config.systemd.package}/bin/systemd-nspawn"
          "--keep-unit"
          "--register=yes"
          "--notify-ready=yes"
          "--kill-signal=SIGRTMIN+3"
          "--machine=max-sandbox-%i"
          "--directory=${runtime.stateDirectory}/roots/max-sb-%i"
          "--private-users=pick"
          "--private-users-ownership=auto"
          # Store files are world-readable and immutable. No ownership mapping
          # is needed here, and omitting it also supports VM/9p-backed stores.
          "--bind-ro=/nix/store:/nix/store"
          "--bind=${runtime.stateDirectory}/volumes/max-sb-%i-data/work:/work:idmap"
          "--tmpfs=/tmp:mode=1777,size=512M"
          "--tmpfs=/home/sandbox:mode=0700,uid=1000,gid=1000,size=256M"
          (toString guestInit)
        ];
        KillMode = "mixed";
        TimeoutStartSec = 90;
        TimeoutStopSec = 30;
        MemoryMax = "4G";
        MemorySwapMax = 0;
        CPUQuota = "200%";
        TasksMax = 512;
        Restart = "no";
      };
    };

    systemd.services."max-browser@" = lib.mkIf cfg.browser.enable {
      description = "Max browser %i";
      partOf = [ "max-stack.target" ];
      restartIfChanged = false;
      environment = {
        HOME = "/var/lib/max-browser/%i";
        XDG_CACHE_HOME = "/var/cache/max-browser/%i";
        MAX_BROWSER_ENDPOINT_FILE = "/run/max-browser-%i/endpoint.json";
        CAMOUFOX_MCP_MAX_SESSIONS = "4";
        CAMOUFOX_MCP_SESSION_TTL_MS = "900000";
      };
      serviceConfig = {
        ExecStart = "${cfg.browser.package}/bin/max-browser";
        DynamicUser = true;
        StateDirectory = "max-browser/%i";
        StateDirectoryMode = "0700";
        CacheDirectory = "max-browser/%i";
        RuntimeDirectory = "max-browser-%i";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/max-browser/%i";
        Slice = "max-browser.slice";
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectProc = "invisible";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        UMask = "0077";
        # Firefox's own sandbox needs user namespaces; its JIT needs executable memory.
        MemoryMax = "4G";
        MemorySwapMax = 0;
        CPUQuota = "200%";
        TasksMax = 512;
        KillMode = "mixed";
        TimeoutStopSec = 30;
        Restart = "no";
        InaccessiblePaths = [
          "-/var/lib/max-bot"
          "-${runtime.stateDirectory}"
          "-/run/max"
          "-/run/max-runtime"
          "-/run/secrets"
        ];
      };
    };
    systemd.services.max = {
      partOf = [ "max-stack.target" ];
      requires = [ "max-runtime.socket" ];
      after = [ "max-runtime.socket" ];
      path = [ client ];
      serviceConfig.Slice = "max.slice";
    };
  };
}
