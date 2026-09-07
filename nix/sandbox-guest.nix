{ lib, pkgs, ... }:
{
  boot.isContainer = true;
  boot.isNspawnContainer = true;
  system.stateVersion = "26.05";
  networking.hostName = lib.mkDefault "max-sandbox";
  networking.useDHCP = false;
  networking.useHostResolvConf = true;
  networking.firewall.enable = false;
  # Only the host broker can build packages or access its Nix daemon.
  nix.enable = false;
  documentation.enable = false;
  services.logrotate.enable = false;
  security.sudo.enable = false;
  users.mutableUsers = false;
  users.allowNoPasswordLogin = true;
  users.users.root.hashedPassword = "!";
  users.groups.sandbox.gid = 1000;
  users.users.sandbox = {
    isNormalUser = true;
    uid = 1000;
    group = "sandbox";
    home = "/home/sandbox";
    createHome = true;
    shell = pkgs.bashInteractive;
  };
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
  systemd.tmpfiles.rules = [
    "d /work 0700 sandbox sandbox -"
    "d /home/sandbox 0700 sandbox sandbox -"
  ];
  # The outer unit caps the whole guest, including commands that daemonize.
  systemd.settings.Manager.DefaultTasksAccounting = true;
  systemd.settings.Manager.DefaultMemoryAccounting = true;
}
