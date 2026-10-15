# The command sandbox: a microvm.nix guest that cloud-hypervisor boots straight
# into its kernel. Commands run as root; the VM boundary is the isolation, so
# the guest has a writable Nix store and its own daemon. / is a tmpfs, /work
# and /nix persist.
#
# The runner starts in a per-boot directory the broker prepares, so the
# relative share sources and the volume below resolve per sandbox: work and
# chat link to the sandbox's volume, meta holds its resolvers and the broker's
# SSH key, and nix.img links to its disk.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  rwStore = "/nix/.rw-store";
  # Registered at boot so Nix does not refetch paths it can already see. It
  # travels on the kernel command line (microvm.kernelParams stays out of the
  # toplevel), which avoids a self-reference.
  registration = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
in
{
  options.maxSandbox.diskSize = lib.mkOption {
    type = lib.types.ints.positive;
    default = 32768;
    description = "Size in MiB of the sandbox disk that holds the writable store.";
  };

  config = {
    system.stateVersion = "26.05";
    networking.hostName = lib.mkDefault "max-sandbox";

    microvm = {
      hypervisor = "cloud-hypervisor";
      # virtiofsd enforces readOnly on the host side, so the VM's root cannot
      # remount these writable.
      shares = [
        {
          proto = "virtiofs";
          tag = "store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          socket = "store.sock";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "chat";
          source = "chat";
          mountPoint = "/chat";
          socket = "chat.sock";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "meta";
          source = "meta";
          mountPoint = "/run/max-meta";
          socket = "meta.sock";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "work";
          source = "work";
          mountPoint = "/work";
          socket = "work.sock";
          # Guest root writes as the host uid that owns /work. Taking that
          # fsuid drops virtiofsd's capabilities, so it cannot create devices.
          posixAcl = false;
          extraArgs = [
            "--translate-uid=map:0:1000:1"
            "--translate-gid=map:0:1000:1"
            "--translate-uid=squash-guest:1:1000:4294967294"
            "--translate-gid=squash-guest:1:1000:4294967294"
          ];
        }
      ];
      writableStoreOverlay = rwStore;
      volumes = [
        {
          image = "nix.img";
          label = "max-nix";
          mountPoint = rwStore;
          size = config.maxSandbox.diskSize;
          fsType = "ext4";
        }
      ];
      # The broker's network unit creates vm0 in the sandbox's namespace and
      # masquerades it, so every guest has the same static address.
      interfaces = [
        {
          type = "tap";
          id = "vm0";
          mac = "02:00:00:00:00:01";
        }
      ];
      # Freed guest pages go back to the host (free page reporting).
      balloon = true;
      # Hybrid vsock at notify.vsock: readiness for the host unit, and SSH.
      vsock.cid = 3;
      vsock.ssh.enable = true;
      socket = "api.sock";
      kernelParams = [ "regInfo=${registration}/registration" ];
    };

    boot.kernelParams = [
      "quiet"
      "systemd.show_status=error"
    ];

    # The Nix database, profiles and GC roots persist with the store overlay.
    fileSystems."/nix/var" = {
      device = "${rwStore}/var";
      fsType = "none";
      options = [
        "bind"
        "x-systemd.requires-mounts-for=${rwStore}"
      ];
      neededForBoot = true;
    };
    boot.initrd.systemd.services.max-nix-var = {
      requiredBy = [ "sysroot-nix-var.mount" ];
      before = [ "sysroot-nix-var.mount" ];
      unitConfig.RequiresMountsFor = "/sysroot${rwStore}";
      serviceConfig.Type = "oneshot";
      script = "mkdir -p -m 0755 /sysroot${rwStore}/var";
    };

    systemd.services.register-nix-paths = {
      unitConfig.DefaultDependencies = false;
      wantedBy = [ "sysinit.target" ];
      before = [
        "sysinit.target"
        "shutdown.target"
        "nix-daemon.socket"
        "nix-daemon.service"
      ];
      after = [ "local-fs.target" ];
      conflicts = [ "shutdown.target" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [[ "$(cat /proc/cmdline)" =~ regInfo=([^ ]*) ]]; then
          ${config.nix.package.out}/bin/nix-store --load-db < "''${BASH_REMATCH[1]}"
        fi
      '';
    };

    networking.useDHCP = false;
    networking.useNetworkd = true;
    networking.firewall.enable = false;
    systemd.network.networks."10-uplink" = {
      matchConfig.MACAddress = "02:00:00:00:00:01";
      address = [ "10.0.2.2/30" ];
      gateway = [ "10.0.2.1" ];
    };
    services.resolved.enable = false;
    networking.resolvconf.enable = false;
    environment.etc."resolv.conf".source = "/run/max-sandbox/resolv.conf";
    systemd.services.max-sandbox-dns = {
      wantedBy = [ "network.target" ];
      before = [ "network.target" ];
      unitConfig.RequiresMountsFor = "/run/max-meta";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "max-sandbox";
        RuntimeDirectoryPreserve = true;
      };
      script = ''
        : > /run/max-sandbox/resolv.conf
        for server in $(cat /run/max-meta/dns); do
          echo "nameserver $server" >> /run/max-sandbox/resolv.conf
        done
      '';
    };

    # systemd-ssh-generator puts sshd on vsock port 22; the broker connects
    # through the hybrid vsock socket with its own key.
    services.openssh = {
      enable = true;
      openFirewall = false;
      settings.PermitRootLogin = "prohibit-password";
      authorizedKeysFiles = [ "/run/max-meta/authorized_keys" ];
    };

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # The registry pins nixpkgs; never fetch the global one.
      flake-registry = "";
      # Commands run in systemd units, which do not get the session's NIX_PATH.
      nix-path = config.nix.nixPath;
      substituters = [
        "https://mirror.sjtu.edu.cn/nix-channels/store"
        "https://cache.nixos.org"
      ];
    };
    nix.channel.enable = false;

    documentation.enable = false;
    services.logrotate.enable = false;
    security.sudo.enable = false;
    users.mutableUsers = false;
    users.allowNoPasswordLogin = true;
    users.users.root.hashedPassword = "!";
    environment.systemPackages = with pkgs; [
      bashInteractive
      coreutils
      curl
      wget
      git
      gnutar
      gzip
      less
      man
      openssh
      gnused
      gawk
      diffutils
      patch
      file
      tree
      bc
      xz
      bzip2
      zstd
      zip
      unzip
      procps
      psmisc
      lsof
      util-linux
      hostname
      iproute2
      iputils
      dnsutils
      netcat-gnu
      socat
      openssl
      rsync
      vim
      nano
      python3
      perl
      jq
      ripgrep
      gnumake
    ];
  };
}
