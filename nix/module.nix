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
  vm = cfg.vm.enable;
  toml = pkgs.formats.toml { };
  max = lib.getExe' cfg.package "max";

  # One tap per VM that can run at a time, each its own /30 cut from the
  # /24: the host's end is .1, the guest's .2. See "VM 进程".
  slots = map (i: {
    tap = "${name}-vm${toString i}";
    address = "${cfg.vm.subnet}.${toString (4 * i + 2)}/30";
    gateway = "${cfg.vm.subnet}.${toString (4 * i + 1)}";
  }) (lib.range 0 (cfg.vm.slots - 1));
  taps = "${name}-vm*";
  forwards =
    key:
    lib.elem (config.boot.kernel.sysctl.${key} or null) [
      1
      true
      "1"
    ];

  # max.service's, and vm-check's, which must run as max does.
  serviceConfig = {
    User = name;
    Group = name;
    Slice = "${name}.slice";
    StateDirectory = name;
    StateDirectoryMode = "0700";
    RuntimeDirectory = name;
    WorkingDirectory = "/var/lib/${name}";

    # What max needs from the host: TCP out (QQ, model providers),
    # Postgres's socket, its state directory. The rest is taken away,
    # except what the VMs need back; see "VM 进程".
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
    # These three lay read-only mounts over /proc, and then the kernel
    # won't let virtiofsd mount a proc of its own in its namespaces.
    ProtectHostname = !vm;
    ProtectKernelTunables = !vm;
    ProtectKernelLogs = !vm;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    # virtiofsd's sandbox.
    RestrictNamespaces =
      if vm then
        [
          "user"
          "mnt"
          "pid"
          "net"
        ]
      else
        true;
    RestrictRealtime = true;
    # Also keeps the guests from making setuid files in /work.
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RemoveIPC = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ] ++ lib.optional vm "@mount";
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
  }
  // lib.optionalAttrs vm {
    # cloud-hypervisor's, in the private /dev.
    BindPaths = [
      "/dev/kvm"
      "/dev/net/tun"
    ];
    DeviceAllow = [
      "/dev/kvm rw"
      "/dev/net/tun rw"
    ];
  };

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

    vm = {
      enable = lib.mkEnableOption ''
        the groups' VMs, where the tools run. The module makes the taps and
        the firewall's rules, and fills in `settings.vm`; the VMs' sizes
        can be set there'';

      guest = lib.mkOption {
        type = lib.types.package;
        default = packages.${pkgs.stdenv.hostPlatform.system}.guest;
        defaultText = lib.literalMD "this flake's `guest`";
        description = "What a VM boots: the flake's `guest`.";
      };

      slots = lib.mkOption {
        type = lib.types.ints.between 1 64;
        default = 32;
        description = "How many VMs can run at a time; one tap each.";
      };

      subnet = lib.mkOption {
        type = lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+";
        default = "10.235.0";
        description = "The /24 the taps' addresses come from, without its last octet.";
      };

      dns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "223.5.5.5"
          "119.29.29.29"
        ];
        description = "The resolvers a guest uses. The guest can't reach the host's.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.${name}.settings = {
      database.url = lib.mkDefault "postgresql:///${name}?host=/run/postgresql&user=${name}";
      media.dir = lib.mkDefault "/var/lib/${name}/media";
      vm = lib.mkIf vm {
        guest = "${cfg.vm.guest}";
        cloud_hypervisor = lib.getExe pkgs.cloud-hypervisor;
        virtiofsd = lib.getExe pkgs.virtiofsd;
        mkfs = "${lib.getBin pkgs.e2fsprogs}/bin/mkfs.ext4";
        dir = "/var/lib/${name}/vm";
        inherit (cfg.vm) dns;
        inherit slots;
      };
    };

    services.postgresql = {
      enable = true;
      # The sticker library's vectors.
      extensions = ps: [ ps.pgvector ];
      ensureDatabases = [ name ];
      ensureUsers = [
        {
          inherit name;
          ensureDBOwnership = true;
        }
      ];
    };

    # pgvector isn't a trusted extension, so max's role can't create it
    # and the migration that needs it would fail. The superuser creates it
    # after the database is made; the migration's `if not exists` then does
    # nothing. postgresql-setup runs as postgres, with psql on its path.
    systemd.services.postgresql-setup.postStart = ''
      psql -d ${name} -tAc 'create extension if not exists vector' >/dev/null
    '';

    users.users.${name} = {
      isSystemUser = true;
      group = name;
      extraGroups = lib.optional vm "kvm";
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
      ]
      ++ lib.optional vm "${name}-taps.service";
      wants = [ "network-online.target" ] ++ lib.optional vm "${name}-taps.service";
      requires = [ "postgresql.target" ];

      serviceConfig = serviceConfig // {
        ExecStart = "${max} run --config ${configFile}";
        Restart = "on-failure";
        RestartSec = 5;
        # SIGTERM goes to max alone, which stops what it started in order;
        # whatever is left after it exits, the VMs among it, is killed with
        # the cgroup.
        KillMode = "mixed";
        TimeoutStopSec = 60;
      };
    };

    # `systemctl start ${name}-vm-check` boots a VM on the last slot, runs
    # `uname -a` in it, a program that calls the MCP service and one that
    # opens a page in the browser, and logs what the model would be shown.
    systemd.services."${name}-vm-check" = lib.mkIf vm {
      description = "Boot one of max's VMs and run a command in it (${name})";
      wants = [ "${name}-taps.service" ];
      after = [
        "${name}-taps.service"
        "${name}.service"
      ];
      serviceConfig = serviceConfig // {
        Type = "oneshot";
        ExecStart = "${max} vm-check --config ${configFile}";
      };
    };

    # The taps, made for max's user, so cloud-hypervisor needs no
    # capability to use one. They outlive this unit, so that restarting it
    # doesn't cut off running VMs; a slot taken away stays until reboot.
    systemd.services."${name}-taps" = lib.mkIf vm {
      description = "The taps for max's VMs (${name})";
      wantedBy = [ "${name}.target" ];
      before = [ "${name}.service" ];
      partOf = [ "${name}.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStrings (slot: ''
        if ! ip link show dev ${slot.tap} >/dev/null 2>&1; then
          ip tuntap add name ${slot.tap} mode tap user ${name} group ${name} multi_queue vnet_hdr
        fi
        ip address replace ${slot.gateway}/30 dev ${slot.tap}
        ip link set dev ${slot.tap} up
      '') slots;
    };
    # A guest reaches the internet and nothing else: not the host, not
    # another guest, not a private network, and only from its own address.
    networking.nftables.enable = lib.mkIf vm (lib.mkDefault true);
    # Forwarding is the host's to turn on: a sysctl takes one value, and
    # modules that need it, nat's among them, each set it at a priority
    # of their own, so a second setter here would clash with one of them.
    assertions = lib.optionals vm [
      {
        assertion = config.networking.nftables.enable;
        message = "${name}'s VMs need nftables.";
      }
      {
        assertion = forwards "net.ipv4.ip_forward" || forwards "net.ipv4.conf.all.forwarding";
        message = "${name}'s VMs need IPv4 forwarding: set boot.kernel.sysctl.\"net.ipv4.ip_forward\" = 1.";
      }
    ];
    networking.firewall.extraForwardRules = lib.mkIf vm ''
      iifname "${taps}" accept
      oifname "${taps}" ct state { established, related } accept
    '';
    networking.nftables.tables."${name}-vm" = lib.mkIf vm {
      family = "inet";
      content = ''
        set non_public_v4 {
          type ipv4_addr
          flags interval
          elements = {
            0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
            169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24,
            192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15,
            198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4
          }
        }
        set guests {
          type ifname . ipv4_addr
          elements = {
            ${lib.concatMapStringsSep ",\n      " (
              slot: "\"${slot.tap}\" . ${lib.head (lib.splitString "/" slot.address)}"
            ) slots}
          }
        }
        chain input {
          type filter hook input priority -10; policy accept;
          iifname "${taps}" ct state { established, related } accept
          iifname "${taps}" counter reject with icmpx type admin-prohibited
        }
        chain forward {
          type filter hook forward priority -10; policy accept;
          iifname "${taps}" meta nfproto ipv6 counter reject with icmpx type admin-prohibited
          iifname "${taps}" iifname . ip saddr != @guests counter drop
          iifname "${taps}" ip daddr @non_public_v4 counter reject with icmpx type admin-prohibited
          oifname "${taps}" ct state != { established, related } counter drop
        }
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr ${cfg.vm.subnet}.0/24 oifname != "${taps}" masquerade
        }
      '';
    };
  };
}
