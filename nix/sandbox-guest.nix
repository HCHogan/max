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
    default = 131072;
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
          # Store paths never change; missing ones are not cached negatively,
          # so packages the broker builds later still appear.
          cache = "always";
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
      # register-nix-paths below does this once per guest system instead of
      # every boot.
      registerClosure = false;
    };

    boot.kernelParams = [
      "quiet"
      "systemd.show_status=error"
      # microvm.nix hands PID1 a vsock notify socket. On cloud-hypervisor
      # before 53 every notification PID1 sends there stalls it ~0.2s, and
      # PID1 sends one every 333ms while it boots. max-sandbox-ready reports
      # readiness once instead.
      "systemd.import_credentials=no"
      "systemd.getty_auto=0"
      # PID1's environment: it handles at most 5 mount table changes a second
      # by default, and boot mounts more than that, so each second's surplus
      # waited for the next.
      "SYSTEMD_DEFAULT_MOUNT_RATE_LIMIT_BURST=1000"
      # Otherwise PID1, in the initrd and again after switching root, queries
      # the serial console for its type and size, and nothing answers: three
      # 333ms timeouts each time.
      "TERM=dumb"
      "systemd.tty.rows.console=24"
      "systemd.tty.columns.console=80"
    ];

    # nixos-init, an overlaid /etc and userborn replace the initrd's
    # activation script.
    system.nixos-init.enable = true;
    system.etc.overlay.enable = true;
    services.userborn.enable = true;

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
      # The database persists, so each guest system registers once.
      script = ''
        if [[ "$(cat /proc/cmdline)" =~ regInfo=([^ ]*) ]]; then
          registration="''${BASH_REMATCH[1]}"
          stamp=/nix/var/nix/max-registered
          if [ "$(cat "$stamp" 2>/dev/null)" != "$registration" ]; then
            ${config.nix.package.out}/bin/nix-store --load-db < "$registration"
            echo "$registration" > "$stamp"
          fi
        fi
      '';
    };

    # The host grows the image when the configured size increases.
    systemd.services.max-nix-grow = {
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = rwStore;
      serviceConfig.Type = "oneshot";
      script = "${pkgs.e2fsprogs}/bin/resize2fs /dev/disk/by-label/max-nix";
    };

    # The initrd loads the NIC, so the static address is set without waiting
    # for udev or networkd.
    boot.initrd.kernelModules = [ "virtio_net" ];
    networking.usePredictableInterfaceNames = false;
    networking.useNetworkd = false;
    networking.useDHCP = false;
    networking.dhcpcd.enable = false;
    networking.firewall.enable = false;
    systemd.services.max-sandbox-uplink = {
      wantedBy = [ "network.target" ];
      before = [ "network.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.iproute2 ];
      script = ''
        ip address replace 10.0.2.2/30 dev eth0
        ip link set eth0 up
        ip route replace default via 10.0.2.1
      '';
    };
    services.resolved.enable = false;
    networking.resolvconf.enable = false;
    environment.etc."resolv.conf".source = "/run/max-sandbox/resolv.conf";
    systemd.services.max-sandbox-dns = {
      wantedBy = [ "network.target" ];
      before = [ "network.target" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = "/run/max-meta";
      };
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
    # through the hybrid vsock socket with its own key. Nothing reaches the
    # TCP listener, which therefore does not start.
    services.openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        PermitRootLogin = "prohibit-password";
        # The broker multiplexes concurrent commands over one connection.
        MaxSessions = 100;
      };
      authorizedKeysFiles = [ "/run/max-meta/authorized_keys" ];
      # / is a tmpfs, so host keys are generated every boot; RSA takes seconds.
      hostKeys = [
        {
          type = "ed25519";
          path = "/etc/ssh/ssh_host_ed25519_key";
        }
      ];
    };
    systemd.services.sshd.wantedBy = lib.mkForce [ ];
    # Commands run in transient units, not login sessions.
    security.pam.services.sshd.startSession = lib.mkForce false;

    # Sent once the broker can run commands, while unrelated units may still
    # be starting. The host's runner relays it to the VM's unit.
    systemd.services.max-sandbox-ready = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
        "register-nix-paths.service"
        "sshd-vsock.socket"
        "sshd-keygen.service"
        # pam_unix's helper, which sshd's account check runs.
        "suid-sgid-wrappers.service"
        "network.target"
      ];
      wants = [ "sshd-keygen.service" ];
      unitConfig.DefaultDependencies = false;
      environment.NOTIFY_SOCKET = "vsock-stream:2:8888";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # The relay is one-way, so no barrier reply ever arrives.
        ExecStart = "${config.systemd.package}/bin/systemd-notify --ready --no-block";
      };
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

    # A headless VM reached only over vsock, whose commands run as root.
    documentation.enable = false;
    console.enable = false;
    services.logrotate.enable = false;
    services.timesyncd.enable = false;
    services.fstrim.enable = false;
    systemd.oomd.enable = false;
    services.journald.storage = "volatile";
    security.sudo.enable = false;
    users.manageLingering = false;
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
