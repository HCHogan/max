# A group's VM: a NixOS guest that cloud-hypervisor boots straight into its
# kernel. max starts it as its own child, with a command line of its own
# making (see docs/rust-rewrite.md, "VM 进程"); this module only builds the
# system, and the flake hands max its kernel, initrd and command line.
#
# Commands run as root; the VM boundary is the isolation, so the guest has a
# writable Nix store and its own daemon. / is a tmpfs; /work and the store's
# upper layer persist in the group's directory on the host.
#
# What differs between groups' VMs comes on the kernel command line, which
# max appends to: the address (max.ip, max.gateway), the resolvers
# (max.dns) and the key max logs in with (max.key).
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
  # run_code's runner, with the browser its programs drive.
  runner = import ./runner.nix { inherit pkgs; };
in
{
  system.stateVersion = "26.05";
  networking.hostName = "max";

  microvm = {
    hypervisor = "cloud-hypervisor";
    # max runs one virtiofsd per share, with these tags and sockets.
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
        tag = "work";
        source = "work";
        mountPoint = "/work";
        socket = "work.sock";
      }
    ];
    writableStoreOverlay = rwStore;
    # max makes the image, sized by its configuration, and formats it.
    volumes = [
      {
        image = "nix.img";
        label = "max-nix";
        mountPoint = rwStore;
        size = 1024;
        fsType = "ext4";
      }
    ];
    # Freed guest pages go back to the host (free page reporting).
    balloon = true;
    # max reaches sshd through the hybrid vsock socket.
    vsock.cid = 3;
    vsock.ssh.enable = true;
    kernelParams = [ "regInfo=${registration}/registration" ];
    # register-nix-paths below does this once per guest system instead of
    # every boot.
    registerClosure = false;
  };

  boot.kernelParams = [
    "quiet"
    "systemd.show_status=error"
    "systemd.getty_auto=0"
    # PID1 handles at most 5 mount table changes a second by default, and
    # boot mounts more than that, so each second's surplus waited for the
    # next.
    "SYSTEMD_DEFAULT_MOUNT_RATE_LIMIT_BURST=1000"
    # Otherwise PID1, in the initrd and again after switching root, queries
    # the serial console for its type and size, and nothing answers.
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

  # max grows the image when the configured size increases.
  systemd.services.max-nix-grow = {
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = rwStore;
    serviceConfig.Type = "oneshot";
    script = "${pkgs.e2fsprogs}/bin/resize2fs /dev/disk/by-label/max-nix";
  };

  # The address, resolvers and max's key, from the command line, before
  # anything uses them. The initrd loads the NIC, so this needn't wait for
  # udev or networkd.
  boot.initrd.kernelModules = [ "virtio_net" ];
  networking.usePredictableInterfaceNames = false;
  networking.useNetworkd = false;
  networking.useDHCP = false;
  networking.dhcpcd.enable = false;
  networking.firewall.enable = false;
  services.resolved.enable = false;
  networking.resolvconf.enable = false;
  environment.etc."resolv.conf".source = "/run/max/resolv.conf";
  systemd.services.max-guest = {
    wantedBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "network-pre.target"
      "sshd-vsock.socket"
    ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "max";
      RuntimeDirectoryPreserve = true;
    };
    path = [ pkgs.iproute2 ];
    script = ''
      for word in $(cat /proc/cmdline); do
        case "$word" in
          max.ip=*) address=''${word#max.ip=} ;;
          max.gateway=*) gateway=''${word#max.gateway=} ;;
          max.dns=*) dns=''${word#max.dns=} ;;
          max.key=*) key=''${word#max.key=} ;;
        esac
      done
      ip address replace "$address" dev eth0
      ip link set eth0 up
      ip route replace default via "$gateway"
      : > /run/max/resolv.conf
      for server in ''${dns//,/ }; do
        echo "nameserver $server" >> /run/max/resolv.conf
      done
      install -m 0600 /dev/null /run/max/authorized_keys
      echo "ssh-ed25519 $key max" > /run/max/authorized_keys
      ln -sfn ${runner}/lib/max-runner/runner.js /run/max/runner.js
    '';
  };

  # run_code's programs reach Max's MCP service at 127.0.0.1:7777. It is on
  # the host, at the hybrid vsock's port 7777: one socat per connection.
  systemd.sockets.max-mcp = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "127.0.0.1:7777" ];
    socketConfig.Accept = true;
  };
  systemd.services."max-mcp@" = {
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat STDIO VSOCK-CONNECT:2:7777";
      StandardInput = "socket";
      StandardError = "journal";
    };
  };

  # systemd-ssh-generator puts sshd on vsock port 22. Nothing reaches the
  # TCP listener, which therefore does not start.
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PermitRootLogin = "prohibit-password";
      # max runs concurrent commands over one connection.
      MaxSessions = 100;
    };
    authorizedKeysFiles = [ "/run/max/authorized_keys" ];
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
  # Chinese, for the browser's pages and whatever else draws text.
  fonts.packages = [ pkgs.noto-fonts-cjk-sans ];
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
    # run_code's runner, and programs' own child processes.
    nodejs
    # A page's text, as Markdown; PDFs through pdftotext.
    (import ./webread.nix { inherit pkgs; })
    poppler-utils
    jq
    ripgrep
    gnumake
  ];
}
