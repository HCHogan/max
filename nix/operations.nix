{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.max;
  ops = cfg.operations;
  namespace = "/run/netns/maxops";
  socket = "/run/max-ops-tailscale/tailscaled.sock";
  resolver = pkgs.writeText "max-ops-resolv.conf" (
    lib.concatMapStrings (ip: "nameserver ${ip}\n") cfg.sandbox.nameservers
  );
  tailscale = "${pkgs.tailscale}/bin/tailscale --socket=${socket}";
in
{
  options.services.max.operations = {
    enable = lib.mkEnableOption "SSH fleet operations through a dedicated Tailscale network namespace";
    allowedGroups = lib.mkOption {
      type = lib.types.listOf lib.types.ints.positive;
      default = [ ];
      description = "QQ conversations whose sandboxes join maxops; all members may operate.";
    };
    allowedGroupsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Runtime file outside the Nix store (a sops-nix secret, say) with more
        groups for {option}`allowedGroups`, separated by commas or whitespace,
        so the group ids appear neither in the store nor in the configuration.
        max-runtime reads it once at start and refuses to start on a malformed
        entry; restart max-runtime.service when it changes (sops-nix
        `restartUnits`).
      '';
    };
    loginServer = lib.mkOption {
      type = lib.types.str;
      description = "Headscale registration URL.";
    };
    authKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime sops-nix preauthkey file, outside the Nix store.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "inner.imdomestic.com";
      description = "MagicDNS suffix for fleet SSH aliases.";
    };
  };
  config = lib.mkIf (cfg.enable && ops.enable) {
    assertions = [
      {
        assertion =
          cfg.sandbox.enable
          && cfg.sandboxNetwork.enable
          && lib.hasPrefix "/" ops.authKeyFile
          && !(lib.hasPrefix "/nix/store/" ops.authKeyFile);
        message = "SSH operations requires sandboxes and a runtime authKeyFile outside the Nix store.";
      }
      {
        assertion =
          ops.allowedGroupsFile == null
          || (lib.hasPrefix "/" ops.allowedGroupsFile && !(lib.hasPrefix "/nix/store/" ops.allowedGroupsFile));
        message = "services.max.operations.allowedGroupsFile must be an absolute runtime path outside the Nix store.";
      }
    ];
    networking.nftables.enable = true;
    networking.firewall.extraForwardRules = ''
      iifname "max-ops-host" accept
      oifname "max-ops-host" ct state established,related accept
    '';
    networking.nftables.tables.max-ops = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority -10; policy accept;
          iifname "max-ops-host" ip saddr != 10.232.0.2 drop
          # Tailnet traffic must use Max's own tunnel, including after a crash.
          iifname "max-ops-host" ip daddr 100.64.0.0/10 drop
          iifname "max-ops-host" ip6 daddr fd7a:115c:a1e0::/48 drop
          iifname "max-ops-host" oifname "${config.services.tailscale.interfaceName}" drop
          oifname "max-ops-host" ct state != { established, related } drop
        }
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr 10.232.0.2 oifname != "max-ops-host" masquerade
        }
      '';
    };
    services.max.sandbox.extraModules = [
      {
        # Fleet SSH uses TCP directly.
        programs.ssh.systemd-ssh-proxy.enable = false;
        programs.ssh.extraConfig = ''
          Host * *.${ops.domain}
            User max
            BatchMode yes
            ConnectTimeout 15
            StrictHostKeyChecking accept-new
            UserKnownHostsFile /work/.ssh/known_hosts
          Host * !*.*
            HostName %h.${ops.domain}
        '';
        systemd.tmpfiles.rules = [ "d /work/.ssh 0700 root root -" ];
      }
    ];
    systemd.services.max-ops-network = {
      description = "Max operations network namespace";
      wantedBy = [ "max-stack.target" ];
      partOf = [ "max-stack.target" ];
      after = [
        "max-sandbox-network.service"
        "nftables.service"
      ];
      requires = [
        "max-sandbox-network.service"
        "nftables.service"
      ];
      before = [ "max-ops-tailscaled.service" ];
      path = [
        pkgs.iproute2
        pkgs.nftables
        pkgs.procps
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Slice = "max.slice";
        PrivateMounts = false;
      };
      script = ''
        set -eu
        if ! ip netns list | grep -q '^maxops\b'; then ip netns add maxops; fi
        if ! ip link show max-ops-host >/dev/null 2>&1; then
          ip link add max-ops-host type veth peer name max-ops-peer
          ip link set max-ops-peer netns maxops
        fi
        ip address replace 10.232.0.1/30 dev max-ops-host
        ip link set max-ops-host up
        ip -n maxops address replace 10.232.0.2/30 dev max-ops-peer
        ip -n maxops link set max-ops-peer up
        ip -n maxops link set lo up
        ip -n maxops route replace default via 10.232.0.1
        # Each operations sandbox VM has its own namespace with a port on this
        # bridge (the broker adds it); maxops masquerades them onto tailscale0
        # and its uplink, whose host rules accept only 10.232.0.2.
        if ! ip -n maxops link show max-ops-sb >/dev/null 2>&1; then
          ip -n maxops link add name max-ops-sb type bridge
        fi
        ip -n maxops address replace 10.233.0.1/16 dev max-ops-sb
        ip -n maxops link set max-ops-sb up
        ip netns exec maxops sysctl -qw net.ipv4.ip_forward=1
        ip netns exec maxops nft -f - <<EOF
        table ip max-ops-sandboxes
        delete table ip max-ops-sandboxes
        table ip max-ops-sandboxes {
          chain input {
            type filter hook input priority filter; policy accept;
            iifname "max-ops-sb" ct state established,related accept
            iifname "max-ops-sb" drop
          }
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            ip saddr 10.233.0.0/16 oifname != "max-ops-sb" masquerade
          }
        }
        EOF
      '';
      # Deleting the namespace also removes the sandboxes' bridge ports; the
      # broker rebuilds those sandboxes on next use.
      preStop = ''
        ip netns del maxops
        ip link del max-ops-host 2>/dev/null || test ! -e /sys/class/net/max-ops-host
      '';
    };
    systemd.services.max-ops-tailscaled = {
      description = "Max dedicated Tailscale client";
      wantedBy = [ "max-stack.target" ];
      partOf = [ "max-stack.target" ];
      requires = [ "max-ops-network.service" ];
      after = [
        "max-ops-network.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      path = [ pkgs.tailscale ];
      serviceConfig = {
        Type = "notify";
        ExecStart = "${pkgs.tailscale}/bin/tailscaled --state=/var/lib/max/tailscale/tailscaled.state --socket=${socket} --tun=tailscale0 --port=41641";
        NetworkNamespacePath = namespace;
        StateDirectory = "max/tailscale";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "max-ops-tailscale";
        RuntimeDirectoryMode = "0700";
        BindReadOnlyPaths = [ "${resolver}:/etc/resolv.conf" ];
        LoadCredential = [ "preauthkey:${ops.authKeyFile}" ];
        Slice = "max.slice";
        Restart = "on-failure";
        RestartSec = 3;
      };
      # Reconcile settings on each daemon start; never discard the node identity.
      postStart = ''
        ${tailscale} up --login-server=${lib.escapeShellArg ops.loginServer} \
          --auth-key="file:$CREDENTIALS_DIRECTORY/preauthkey" \
          --hostname=maxops --accept-routes=true --accept-dns=false --ssh=false --timeout=20s
      '';
    };
  };
}
