{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.max;
  runtime = cfg.runtime;
  # Operations sandboxes share the maxops namespace. Its tailscaled runs with
  # --accept-dns=false, so 100.100.100.100 answers tailnet names only and
  # returns SERVFAIL for everything else; glibc then asks the public servers.
  operationsDns = [ "100.100.100.100" ] ++ cfg.sandbox.nameservers;
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
          operationsGroups = lib.optionals cfg.operations.enable cfg.operations.allowedGroups;
          inherit operationsDns;
          network =
            if cfg.sandboxNetwork.enable then config.networking.nftables.tables.max-sandbox.content else null;
        }
      )
    );
  brokerConfig = pkgs.writeText "max-runtime.json" (
    builtins.toJSON {
      user = "max-service";
      stateDirectory = runtime.stateDirectory;
      gcRootsDirectory = "${runtime.stateDirectory}/gcroots";
      legacyVolumeDirectory = "/var/lib/docker/volumes";
      nixpkgs = toString cfg.sandbox.nixpkgs;
      system = pkgs.stdenv.hostPlatform.system;
      bridge = "max-sb-native";
      subnet = "10.231.0.0/16";
      gateway = "10.231.0.1";
      dns = cfg.sandbox.nameservers;
      operationsGroups = lib.optionals cfg.operations.enable cfg.operations.allowedGroups;
      operationsGroupsFile = if cfg.operations.enable then cfg.operations.allowedGroupsFile else null;
      inherit operationsDns;
      # Max fills each conversation's view; the broker owns the directories.
      chatViews = "${cfg.mediaDirectory}/views";
      # Each backend adopts only its own effective template. A browser package
      # change must not invalidate unrelated, running command sandboxes.
      generations =
        lib.optionalAttrs cfg.sandbox.enable { sandbox = instancePolicy "sandbox"; }
        // lib.optionalAttrs cfg.browser.enable { browser = instancePolicy "browser"; };
      # The key the broker logs into every sandbox VM with; the public half
      # reaches each guest through its meta share.
      sshKey = "${runtime.stateDirectory}/ssh/id_ed25519";
      # Operations sandboxes reach the maxops namespace through this bridge.
      operationsBridge = "max-ops-sb";
      operationsGateway = "10.233.0.1";
      commands = {
        systemctl = "${config.systemd.package}/bin/systemctl";
        systemd-run = "${config.systemd.package}/bin/systemd-run";
        ssh = "${pkgs.openssh}/bin/ssh";
        ssh-proxy = "${config.systemd.package}/lib/systemd/systemd-ssh-proxy";
        ip = "${pkgs.iproute2}/bin/ip";
        bridge = "${pkgs.iproute2}/bin/bridge";
        nix = "${pkgs.nix}/bin/nix";
        mount = "${pkgs.util-linux}/bin/mount";
      };
    }
  );
  client = cfg.package;
  runner = cfg.sandbox.package;
  # Runs inside the sandbox's namespace before the VM: the guest's tap,
  # masqueraded onto the namespace's eth0, so the host's egress policy sees
  # the namespace's own address.
  vmNetwork = pkgs.writeShellScript "max-sandbox-vm-network" ''
    set -eu
    ip link del vm0 2>/dev/null || true
    ip tuntap add name vm0 mode tap $(cat ${runner}/share/microvm/tap-flags)
    ip address add 10.0.2.1/30 dev vm0
    ip link set vm0 up
    echo 1 > /proc/sys/net/ipv4/ip_forward
    nft -f - <<EOF
    table ip max-vm
    delete table ip max-vm
    table ip max-vm {
      chain forward {
        type filter hook forward priority filter; policy drop;
        iifname "vm0" oifname "eth0" accept
        iifname "eth0" oifname "vm0" ct state established,related accept
      }
      chain input {
        type filter hook input priority filter; policy accept;
        iifname "vm0" ct state established,related accept
        iifname "vm0" drop
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "eth0" masquerade
      }
    }
    EOF
  '';
  # The runner creates missing images at the configured size; existing ones
  # grow here and the guest resizes its file system online.
  growDisk = pkgs.writeShellScript "max-sandbox-grow-disk" ''
    set -eu
    size=${toString (cfg.sandbox.diskSize * 1024 * 1024 * 1024)}
    if [ -e nix.img ] && [ "$(${pkgs.coreutils}/bin/stat -L -c %s nix.img)" -lt "$size" ]; then
      ${pkgs.coreutils}/bin/truncate -s "$size" nix.img
    fi
  '';
in
{
  imports = [
    (lib.mkRemovedOptionModule [
      "services"
      "max"
      "sandbox"
      "renderDevice"
    ] "Sandboxes are VMs now and cannot share the host's render node.")
  ];

  options.services.max = {
    runtime.stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/max/runtime";
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
        description = "microvm.nix runner (config.microvm.declaredRunner) of the sandbox guest.";
      };
      memory = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8192;
        description = "Guest RAM in MiB. Pages are allocated on use and freed pages return to the host.";
      };
      cpus = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Guest vCPUs; the VM's CPU quota matches.";
      };
      diskSize = lib.mkOption {
        type = lib.types.ints.positive;
        default = 128;
        description = "Size in GiB of each sandbox's sparse disk, which holds its writable Nix store. Existing disks grow to it at their next boot.";
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
      data = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        example = lib.literalExpression ''{ destiny = ./data/destiny-guides; }'';
        description = ''
          Reference data at /data/<name> in every command sandbox, a link into
          the host store the guest already shares read-only. Use store paths:
          a changed path rebuilds the guest, and sandboxes restart around their
          volumes on next use.
        '';
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
      "d ${runtime.stateDirectory}/gcroots 0700 root root -"
    ];
    systemd.sockets.max-runtime = {
      description = "Max instance control socket";
      partOf = [ "max-stack.target" ];
      socketConfig = {
        ListenStream = "/run/max-runtime/control.sock";
        SocketUser = "max-service";
        SocketGroup = "max-service";
        SocketMode = "0600";
        DirectoryMode = "0755";
        RemoveOnStop = true;
      };
    };
    systemd.services.max-runtime = {
      description = "Max restricted instance broker";
      partOf = [ "max-stack.target" ];
      requires = [
        "max-runtime.socket"
        "max-storage.service"
        "max-media.service"
      ];
      after = [
        "max-runtime.socket"
        "max-storage.service"
        "max-media.service"
      ]
      ++ lib.optional cfg.sandbox.enable "max-sandbox-network.service";
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "max-runtime-ssh-key" ''
          set -eu
          mkdir -p -m 0700 ${runtime.stateDirectory}/ssh
          test -s ${runtime.stateDirectory}/ssh/id_ed25519 || \
            ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C max-runtime -f ${runtime.stateDirectory}/ssh/id_ed25519
        '';
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
          # systemd-ssh-proxy reaches sandbox VMs over vsock.
          "AF_VSOCK"
        ];
      };
    };

    # The host's sizing and reference data, applied to the guest build.
    services.max.sandbox.extraModules = [
      {
        microvm.mem = cfg.sandbox.memory;
        microvm.vcpu = cfg.sandbox.cpus;
        maxSandbox.diskSize = cfg.sandbox.diskSize * 1024;
        # Store paths, which the guest already sees through its store share.
        systemd.tmpfiles.rules = lib.mapAttrsToList (
          name: path: "L+ /data/${name} - - - - ${path}"
        ) cfg.sandbox.data;
      }
    ];

    # Both units start in the per-boot directory the broker prepares, where
    # the runner's relative share sources, sockets and volume resolve.
    systemd.services."max-sandbox-virtiofsd@" = lib.mkIf cfg.sandbox.enable {
      description = "Max sandbox VM %i file shares";
      partOf = [ "max-sandbox@%i.service" ];
      before = [ "max-sandbox@%i.service" ];
      restartIfChanged = false;
      serviceConfig = {
        # cloud-hypervisor retries its share sockets until they appear, so the
        # VM starts alongside instead of after microvm.nix's supervisor, which
        # takes 2s to report the daemons running.
        Type = "exec";
        Slice = "max-sandbox.slice";
        WorkingDirectory = "${runtime.stateDirectory}/roots/max-sb-%i";
        ExecStart = "${runner}/bin/virtiofsd-run";
        # The supervisor alone waits seconds for its listener to exit.
        KillMode = "control-group";
        TimeoutStopSec = 15;
        Restart = "no";
      };
    };

    systemd.services."max-sandbox@" = lib.mkIf cfg.sandbox.enable {
      description = "Max sandbox VM %i";
      partOf = [ "max-stack.target" ];
      bindsTo = [ "max-sandbox-virtiofsd@%i.service" ];
      requires = [ "max-sandbox-network.service" ];
      after = [
        "max-sandbox-network.service"
        "max-sandbox-virtiofsd@%i.service"
      ]
      ++ lib.optionals cfg.operations.enable [
        "max-ops-network.service"
        "max-ops-tailscaled.service"
      ];
      restartIfChanged = false;
      path = [
        pkgs.iproute2
        pkgs.nftables
      ];
      serviceConfig = {
        # The runner relays the guest's readiness from its vsock.
        Type = "notify";
        NotifyAccess = "all";
        Slice = "max-sandbox.slice";
        NetworkNamespacePath = "/run/netns/max-sb-%i";
        WorkingDirectory = "${runtime.stateDirectory}/roots/max-sb-%i";
        ExecStartPre = [
          "${growDisk}"
          "${vmNetwork}"
        ];
        ExecStart = "${runner}/bin/microvm-run";
        ExecStop = "${runner}/bin/microvm-shutdown";
        KillMode = "mixed";
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        # Guest RAM plus cloud-hypervisor's own.
        MemoryMax = "${toString (cfg.sandbox.memory + 512)}M";
        MemorySwapMax = 0;
        CPUQuota = "${toString (cfg.sandbox.cpus * 100)}%";
        TasksMax = 1024;
        Restart = "no";
      };
    };

    systemd.services."max-browser@" = lib.mkIf cfg.browser.enable {
      description = "Max browser %i";
      partOf = [ "max-stack.target" ];
      requires = [ "max-storage.service" ];
      after = [ "max-storage.service" ];
      restartIfChanged = false;
      environment = {
        HOME = "/var/lib/max/browser/%i";
        XDG_CACHE_HOME = "/var/lib/max/browser-cache/%i";
        MAX_BROWSER_ENDPOINT_FILE = "/run/max-browser-%i/endpoint.json";
        # Launch options are host-owned; no model-facing session-start tool.
        CAMOUFOX_MCP_ALLOW_UNSAFE_OPTIONS = "1";
        # The fork additionally requires an active task workspace lease.
        CAMOUFOX_MCP_ALLOW_EVALUATE = "1";
        CAMOUFOX_MCP_MAX_SESSIONS = "4";
        CAMOUFOX_MCP_SESSION_TTL_MS = "900000";
      };
      serviceConfig = {
        ExecStart = "${cfg.browser.package}/bin/max-browser";
        DynamicUser = true;
        StateDirectory = [
          "max/browser/%i"
          "max/browser-cache/%i"
        ];
        StateDirectoryMode = "0700";
        RuntimeDirectory = "max-browser-%i";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/max/browser/%i";
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
        # One Camoufox session measured about 175 tasks (7 processes) on a
        # single page, and multi-site pages add a content process per site.
        # Four sessions (CAMOUFOX_MCP_MAX_SESSIONS) plus their virtual
        # displays and the MCP server overran 512, and fork then failed with
        # EAGAIN; this still bounds a runaway page.
        TasksMax = 2048;
        KillMode = "mixed";
        TimeoutStopSec = 30;
        Restart = "no";
        InaccessiblePaths = [
          "-/var/lib/max/app"
          "-${cfg.mediaDirectory}"
          "-/var/lib/max/napcat"
          "-/var/lib/max/private"
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
