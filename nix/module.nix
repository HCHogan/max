# The NixOS module, as a function of the service's name. Everything it
# makes is named after it: the options under services.<name>, the user,
# the Postgres cluster with its database and role, the directories, the
# slice, the target and the service. So the Rust version runs on tank as
# "maxx" beside the Haskell "max", and takes its place later by changing
# the one name.
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

  # max's own Postgres: a cluster for its database alone, reached on its
  # socket only. See "Its database" in docs/design/config.md.
  pg = cfg.postgresql.package;
  dbUser = "${name}-postgres";
  dbDir = "/var/lib/${name}-postgres";
  dbSocket = "/run/${name}-postgres";
  pgValue =
    value:
    if lib.isBool value then
      lib.boolToString value
    else if lib.isString value then
      "'${lib.replaceStrings [ "'" ] [ "''" ] value}'"
    else
      toString value;
  pgConf = pkgs.writeText "${name}-postgresql.conf" (
    lib.concatStrings (
      lib.mapAttrsToList (key: value: "${key} = ${pgValue value}\n") cfg.postgresql.settings
    )
  );
  # A local user connects as the role of its own name: max as max, which
  # owns its database, and the cluster's user as the superuser.
  pgHba = pkgs.writeText "${name}-pg_hba.conf" ''
    local all all peer
  '';
  # A cluster where there is none. There is no version in the directory's
  # name, and Postgres refuses another major version's data: a new major
  # version stops here, and never starts an empty cluster beside the old.
  pgInit = pkgs.writeShellScript "${name}-postgres-init" ''
    if ! [ -e ${dbDir}/PG_VERSION ]; then
      ${pg}/bin/initdb --pgdata=${dbDir} --username=${dbUser} \
        --auth-local=peer --auth-host=reject \
        ${lib.escapeShellArgs (import ./initdb.nix)}
    fi
  '';
  # max's role and database, made when they aren't there.
  pgSetup = pkgs.writeShellScript "${name}-postgres-setup" ''
    ${pg}/bin/psql --host=${dbSocket} --dbname=postgres --no-psqlrc --quiet \
      --set=ON_ERROR_STOP=1 --set=name=${name} <<'EOF'
    select format('create role %I login', :'name')
    where not exists (select from pg_roles where rolname = :'name') \gexec
    select format('create database %I owner %I', :'name', :'name')
    where not exists (select from pg_database where datname = :'name') \gexec
    EOF
  '';
  # psql in max's database as the cluster's superuser, for root.
  dbPsql = pkgs.writeShellApplication {
    name = "${name}-psql";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      exec runuser -u ${dbUser} -- ${pg}/bin/psql --host=${dbSocket} --dbname=${name} "$@"
    '';
  };

  # One tap per VM that can run at a time, each its own /30 cut from the
  # /24: the host's end is .1, the guest's .2. See "VM processes".
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

  # What max needs from the host: TCP out (QQ, model providers), Postgres's
  # socket, its state directory. The rest is taken away. A VM's unit gets
  # back what its processes need (`forVm`); max itself, which only asks
  # systemd for the VMs, doesn't. See "VM processes".
  sandbox = forVm: {
    User = name;
    Group = name;
    Slice = "${name}.slice";
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
    ProtectHostname = !forVm;
    ProtectKernelTunables = !forVm;
    ProtectKernelLogs = !forVm;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    # virtiofsd's sandbox.
    RestrictNamespaces =
      if forVm then
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
    SystemCallFilter = [ "@system-service" ] ++ lib.optional forVm "@mount";
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
  // lib.optionalAttrs forVm {
    # The store's virtiofsd holds a descriptor for each file the guest has
    # looked up, until the guest forgets it; a guest can walk the host's
    # whole store, 6.4 million files on tank in 2026-10. Each costs the
    # host about 1.4 KB of kernel memory while held.
    LimitNOFILE = 8388608;
    # cloud-hypervisor's, in the private /dev.
    BindPaths = [
      "/dev/kvm"
      "/dev/net/tun"
    ];
    DeviceAllow = [
      "/dev/kvm rw"
      "/dev/net/tun rw"
    ];
    # The VMs' directories: max's state, which the unit doesn't own.
    ReadWritePaths = [ vmDir ];
  };

  # max.service's, and vm-check's, which must run as max does.
  serviceConfig =
    sandbox false
    // {
      StateDirectory = name;
      StateDirectoryMode = "0700";
      RuntimeDirectory = name;
      WorkingDirectory = "/var/lib/${name}";
    }
    // lib.optionalAttrs vm {
      # Where max roots the images its VMs run; see `roots` below.
      ReadWritePaths = [ roots ];
    };

  # Each conversation's VM keeps its files in a directory here.
  vmDir = "/var/lib/${name}/vm";
  # A VM's unit, by instance: the VM's directory under `vmDir`.
  vmUnit = "${name}-vm@";
  # A link here to a store path is a root of the garbage collector's: max
  # links the image each running VM booted, which a deploy may have
  # replaced since.
  roots = "/nix/var/nix/gcroots/per-user/${name}";

  # A VM's processes: two virtiofsd and cloud-hypervisor, as max started
  # them itself until 2026-11-12, with the command lines checked on tank.
  # What differs from boot to boot comes from the unit's EnvironmentFile,
  # which max writes before it starts the unit. cloud-hypervisor is the
  # unit's main process: when it ends, the guest having powered off or
  # been stopped, systemd ends the rest.
  vmStart = pkgs.writeShellApplication {
    name = "${name}-vm";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      dir=$1
      cd "$dir"
      rm -f store.sock work.sock notify.vsock
      # The guest's root is max on the host; its other users are squashed
      # to max.
      uid=$(stat -c %u "$dir")
      gid=$(stat -c %g "$dir")
      # A virtiofsd, which takes the VM with it when it ends. It serves
      # the one connection cloud-hypervisor makes and ends with that, and
      # nothing starts another. A guest that resets, by a reboot or a
      # panic (its command line has `reboot=t panic=-1`), is booted again
      # by cloud-hypervisor in the same process, over new connections
      # that nothing would answer: it waits a minute for them, a unit that
      # runs with no guest in it, and takes no SIGTERM meanwhile. Killed
      # instead, it leaves a unit that has ended, which max boots again
      # when the VM is next needed. $$ is this script, and so
      # cloud-hypervisor once the script has become it.
      share() {
        local log=$1
        shift
        ${lib.getExe pkgs.virtiofsd} "$@" > "$log" 2>&1 || true
        if kill -0 $$ 2> /dev/null; then
          echo "virtiofsd ended ($log) under a VM that ran: the guest reset, or virtiofsd failed, and the VM ends with it" >&2
          kill -KILL $$
        fi
      }
      share virtiofsd-store.log --socket-path="$dir/store.sock" \
        --shared-dir=/nix/store --readonly --cache=always &
      share virtiofsd-work.log --socket-path="$dir/work.sock" \
        --shared-dir="$dir/work" \
        --translate-uid="map:0:$uid:1" --translate-gid="map:0:$gid:1" \
        --translate-uid="squash-guest:1:$uid:4294967294" \
        --translate-gid="squash-guest:1:$gid:4294967294" &
      for socket in store.sock work.sock; do
        for _ in $(seq 250); do
          [ -e "$socket" ] && break
          sleep 0.02
        done
        [ -e "$socket" ] || { echo "virtiofsd didn't make $socket" >&2; exit 1; }
      done
      exec ${lib.getExe pkgs.cloud-hypervisor} \
        --cpus "boot=$CPUS" \
        --memory "size=''${MEMORY_MIB}M,shared=on" \
        --kernel "$KERNEL" --initramfs "$INITRD" --cmdline "$CMDLINE" \
        --seccomp true --landlock --landlock-rules \
        path=/sys/devices/virtual/net,access=r "path=$dir,access=rw" \
        --console off --serial "file=$dir/serial.log" \
        --vsock "cid=3,socket=$dir/notify.vsock" \
        --balloon deflate_on_oom=on,free_page_reporting=on,size=0M \
        --disk "path=$dir/nix.img,image_type=raw" \
        --fs "socket=$dir/store.sock,tag=store" "socket=$dir/work.sock,tag=work" \
        --net "mac=02:00:00:00:00:01,num_queues=$((2 * CPUS)),tap=$TAP" \
        > cloud-hypervisor.log 2>&1
    '';
  };

  # A running VM is a machine of the host's: `machinectl list` shows it as
  # ${name}-7, tied to its unit, and `machinectl status` and `terminate`
  # take it. Run as root after the unit's main process is there, which
  # execs cloud-hypervisor: the machine's leader. A name left by a boot
  # that just ended is dropped first. machined forgets the machine when
  # its leader ends. `machinectl login` and `shell` take no VM: machined
  # opens those in containers only, and `ssh machine/…` wants a vsock
  # the host's kernel reaches, which cloud-hypervisor's isn't. The way
  # in is ${name}-ssh, below.
  vmRegister = pkgs.writeShellScript "${name}-vm-register" ''
    machine=${name}-$1
    machined() {
      ${config.systemd.package}/bin/busctl --timeout=5 --quiet call \
        org.freedesktop.machine1 /org/freedesktop/machine1 \
        org.freedesktop.machine1.Manager "$@"
    }
    machined UnregisterMachine s "$machine" 2> /dev/null
    # No id, no root directory.
    machined RegisterMachine sayssus "$machine" 0 ${name} vm "$MAINPID" ""
  '';

  # A shell in a conversation's VM, or a command there, as root in the
  # guest: for debugging, by whoever reads max's files on the host, which
  # is root. It goes in as max does, to the guest's sshd on the VM's vsock
  # socket, which asks for nothing.
  vmSsh = pkgs.writeShellApplication {
    name = "${name}-ssh";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      if [ $# -eq 0 ]; then
        echo "usage: ${name}-ssh CONVERSATION [COMMAND...]" >&2
        exit 2
      fi
      dir=${vmDir}/$1
      shift
      if ! [ -S "$dir/notify.vsock" ]; then
        echo "${name}-ssh: no VM's socket at $dir/notify.vsock: it isn't running, or this isn't root" >&2
        exit 1
      fi
      exec ssh -o User=root \
        -o ProxyCommand="${config.systemd.package}/lib/systemd/systemd-ssh-proxy vsock-mux$dir/notify.vsock %p" \
        -o ProxyUseFdpass=yes -o CheckHostIP=no -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        ${name}-vm "$@"
    '';
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
        docs/design/config.md.
      '';
    };

    postgresql = {
      package = lib.mkOption {
        type = lib.types.package;
        default = packages.${pkgs.stdenv.hostPlatform.system}.postgresql;
        defaultText = lib.literalMD "this flake's `postgresql`";
        description = ''
          The Postgres of max's own cluster. Another major version doesn't
          start on this one's data, which is moved by hand: see "Its
          database" in docs/design/config.md.'';
      };

      settings = lib.mkOption {
        type =
          with lib.types;
          attrsOf (oneOf [
            bool
            int
            float
            str
          ]);
        default = { };
        example = {
          shared_buffers = "1GB";
        };
        description = ''
          postgresql.conf. The module sets the socket, the authentication
          and no TCP.'';
      };
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
    services.${name} = {
      settings = {
        database.url = lib.mkDefault "postgresql:///${name}?host=${dbSocket}&user=${name}";
        media.dir = lib.mkDefault "/var/lib/${name}/media";
        vm = lib.mkIf vm {
          guest = "${cfg.vm.guest}";
          mkfs = "${lib.getBin pkgs.e2fsprogs}/bin/mkfs.ext4";
          dir = vmDir;
          systemctl = "${config.systemd.package}/bin/systemctl";
          unit = vmUnit;
          inherit roots;
          inherit (cfg.vm) dns;
          inherit slots;
        };
      };

      postgresql.settings = {
        listen_addresses = "";
        unix_socket_directories = dbSocket;
        hba_file = "${pgHba}";
        # journald stamps the time.
        log_line_prefix = lib.mkDefault "[%p] ";
        # Its unit denies memory that is written and run.
        jit = false;
      };
    };

    users.users.${name} = {
      isSystemUser = true;
      group = name;
      extraGroups = lib.optional vm "kvm";
    };
    users.groups.${name} = { };

    users.users.${dbUser} = {
      isSystemUser = true;
      group = dbUser;
    };
    users.groups.${dbUser} = { };

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
      after = [
        "network-online.target"
        "${name}-postgres.service"
      ]
      ++ lib.optional vm "${name}-taps.service"
      ++ lib.optional vm "${name}.socket";
      wants = [ "network-online.target" ] ++ lib.optional vm "${name}-taps.service";
      # A restart of the cluster restarts max.
      requires = [ "${name}-postgres.service" ] ++ lib.optional vm "${name}.socket";
      # A deploy restarts max in one step, with its socket, below, left
      # as it is. Stopped first and started after, as a changed unit is
      # otherwise, a unit that has a socket has the socket stopped with
      # it, and is left for the socket to start: what the VMs asked
      # meanwhile would be refused, and max wouldn't run until one asked.
      stopIfChanged = false;
      serviceConfig =
        serviceConfig
        // {
          ExecStart = "${max} run --config ${configFile}";
          Restart = "on-failure";
          RestartSec = 5;
          # SIGTERM goes to max alone, which stops what it started in order;
          # whatever is left after it exits is killed with the cgroup. The
          # VMs aren't in it: they are units of their own, and stay.
          KillMode = "mixed";
          TimeoutStopSec = 60;
        }
        // lib.optionalAttrs vm {
          # The socket, below, is max's standard input: max takes it from
          # there (`given` in crates/max/src/vm.rs).
          StandardInput = "socket";
          StandardOutput = "journal";
          StandardError = "journal";
        };
    };

    # max's own Postgres, which nothing else on the host shares.
    systemd.services."${name}-postgres" = {
      description = "max's Postgres (${name})";
      wantedBy = [ "${name}.target" ];
      partOf = [ "${name}.target" ];
      serviceConfig = {
        Type = "notify";
        User = dbUser;
        Group = dbUser;
        Slice = "${name}.slice";
        StateDirectory = "${name}-postgres";
        StateDirectoryMode = "0700";
        # The socket's, which max, another user, connects to.
        RuntimeDirectory = "${name}-postgres";
        RuntimeDirectoryMode = "0755";
        ExecStartPre = pgInit;
        ExecStart = "${pg}/bin/postgres -D ${dbDir} -c config_file=${pgConf}";
        ExecStartPost = pgSetup;
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        # A fast shutdown: open transactions roll back.
        KillSignal = "SIGINT";
        KillMode = "mixed";
        TimeoutSec = 120;
        Restart = "on-failure";
        RestartSec = 5;
        # A socket in the file system works across network namespaces.
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        DevicePolicy = "closed";
        PrivateMounts = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelTunables = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged @resources"
        ];
        UMask = "0077";
      };
    };

    # Where the VMs' guests reach max, each VM's port for the host being a
    # link to it: systemd listens there, whether max runs or not, and max
    # is given the socket when it starts. What a
    # guest asks while max restarts, as at every deploy, waits at it, and
    # the max that comes answers; nothing in a guest asks twice. It is the
    # target's as max is: `systemctl stop ${name}.target` stops both. With
    # max's unit alone stopped the socket still listens, and the next
    # thing a guest asks starts max again; to keep max down, stop
    # ${name}.socket too.
    systemd.sockets.${name} = lib.mkIf vm {
      description = "Where the VMs' guests reach max (${name})";
      wantedBy = [ "${name}.target" ];
      partOf = [ "${name}.target" ];
      listenStreams = [ "${vmDir}/max.sock" ];
      socketConfig = {
        SocketUser = name;
        SocketGroup = name;
        SocketMode = "0600";
        # On a host max has never run on, its state directory isn't there
        # yet: max's unit takes it over when it starts.
        DirectoryMode = "0700";
      };
    };

    # A group's VM, which max starts and stops through systemd and which
    # outlives max: a restart of max, as at every deploy, leaves the VMs
    # and what runs in them, and max attaches to them when it is back. A
    # deploy that changes this unit doesn't restart them either; a VM gets
    # the new one when it next boots. See "A VM outlives max" in
    # docs/design/vm.md.
    systemd.services.${vmUnit} = lib.mkIf vm {
      description = "A group's VM (${name}, %I)";
      partOf = [ "${name}.target" ];
      restartIfChanged = false;
      serviceConfig = sandbox true // {
        EnvironmentFile = "${vmDir}/%I/boot.env";
        ExecStart = "${vmStart}/bin/${name}-vm ${vmDir}/%I";
        # Not what the VM needs to run: a failure is only logged.
        ExecStartPost = "-+${vmRegister} %i";
        TimeoutStopSec = 10;
      };
    };
    environment.systemPackages = [ dbPsql ] ++ lib.optional vm vmSsh;

    # max's user starts and stops the VMs' units, and no other.
    security.polkit.enable = lib.mkIf vm true;
    security.polkit.extraConfig = lib.mkIf vm ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "${name}" &&
            action.lookup("unit").indexOf("${vmUnit}") == 0) {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.tmpfiles.rules = lib.mkIf vm [ "d ${roots} 0755 ${name} ${name} -" ];

    # `systemctl start ${name}-vm-check` boots a VM on the last slot, runs
    # `uname -a` in it, a program that calls max's service and one that
    # opens a page in the browser, keeps a unit in /work/.max/systemd and
    # runs a background command, and logs what the model would be shown.
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
