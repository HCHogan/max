# The NixOS module, as a function of the service's name. Everything it
# makes is named after it: the options under services.<name>, the user,
# the database and its role, the directories, the slice, the target and
# the service. So the Rust version runs on tank as "maxx" beside the
# Haskell "max", and takes its place later by changing the one name.
{ name, packages }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.${name};
  toml = pkgs.formats.toml { };
  max = lib.getExe' cfg.package "max";

  # A configuration max won't take fails the system build rather than the
  # service's start. check-config reads none of the secrets it names.
  configFile =
    pkgs.runCommand "${name}.toml"
      {
        unchecked = toml.generate "${name}-unchecked.toml" cfg.settings;
      }
      ''
        ${max} check-config --config "$unchecked"
        cp "$unchecked" "$out"
      '';
in
{
  options.services.${name} = {
    enable = lib.mkEnableOption "Max, the group chat agent, as ${name}";

    package = lib.mkOption {
      type = lib.types.package;
      default = packages.${pkgs.stdenv.hostPlatform.system}.max;
      defaultText = lib.literalMD "this flake's `max` for the host's system";
      description = "The package with the `max` binary.";
    };

    settings = lib.mkOption {
      inherit (toml) type;
      default = { };
      description = ''
        max's configuration, written to a TOML file. Secrets go in as paths
        to files, such as `platforms.qq.app_secret_file`. See
        docs/rust-rewrite.md's section on configuration.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.${name}.settings.database.url =
      lib.mkDefault "postgresql://${name}@/${name}?host=/run/postgresql";

    services.postgresql = {
      enable = true;
      ensureDatabases = [ name ];
      ensureUsers = [
        {
          inherit name;
          ensureDBOwnership = true;
        }
      ];
    };

    users.users.${name} = {
      isSystemUser = true;
      group = name;
    };
    users.groups.${name} = { };

    # Every process Max runs, the VMs included once there are any, so its
    # resources are counted apart from everything else on the host.
    systemd.slices.${name}.description = "Max (${name})";

    systemd.targets.${name} = {
      description = "Max (${name})";
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.${name} = {
      description = "Max, the group chat agent (${name})";
      wantedBy = [ "${name}.target" ];
      partOf = [ "${name}.target" ];
      # The target runs postgresql-setup, which makes the role and database.
      after = [
        "network-online.target"
        "postgresql.target"
      ];
      wants = [ "network-online.target" ];
      requires = [ "postgresql.target" ];

      serviceConfig = {
        ExecStart = "${max} run --config ${configFile}";
        User = name;
        Group = name;
        Slice = "${name}.slice";
        StateDirectory = name;
        StateDirectoryMode = "0700";
        RuntimeDirectory = name;
        WorkingDirectory = "/var/lib/${name}";
        Restart = "on-failure";
        RestartSec = 5;
        # SIGTERM goes to max alone, which stops what it started in order;
        # whatever is left after it exits is killed with the cgroup.
        KillMode = "mixed";
        TimeoutStopSec = 60;

        # What max needs from the host: TCP out (QQ, model providers),
        # Postgres's socket, its state directory. The rest is taken away.
        # The VMs will need some of it back.
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateMounts = true;
        # The service's uid stays itself, for Postgres's peer auth and the
        # secrets it owns; other users map to nobody.
        PrivateUsers = true;
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
        MemoryDenyWriteExecute = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        SystemCallErrorNumber = "EPERM";
        # Netlink for getaddrinfo's address sorting; without it a
        # dual-stack host can be tried in the wrong order first.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        UMask = "0077";
      };
    };
  };
}
