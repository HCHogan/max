# Native nspawn public egress. Isolated bridge ports prevent sibling traffic.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.max;
  bridge = "max-sb-native";
in
{
  options.services.max.sandboxNetwork.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Provision native sandbox public IPv4 egress; disable only with an equivalent externally managed policy.";
  };
  config = lib.mkIf (cfg.enable && cfg.sandbox.enable && cfg.sandboxNetwork.enable) {
    networking.nftables.enable = lib.mkDefault true;
    assertions = [
      {
        assertion = config.networking.nftables.enable;
        message = "Max sandbox public egress requires nftables filtering.";
      }
    ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;
    networking.firewall.extraForwardRules = ''
      iifname "${bridge}" accept
      oifname "${bridge}" ct state { established, related } accept
    '';
    networking.nftables.tables.max-sandbox = {
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
        chain input {
          type filter hook input priority -10; policy accept;
          iifname "${bridge}" ct state { established, related } accept
          iifname "${bridge}" counter reject with icmpx type admin-prohibited
        }
        chain forward {
          type filter hook forward priority -10; policy accept;
          iifname "${bridge}" meta nfproto ipv6 counter reject with icmpx type admin-prohibited
          iifname "${bridge}" ip saddr != 10.231.0.0/16 counter drop
          iifname "${bridge}" ip daddr @non_public_v4 counter reject with icmpx type admin-prohibited
          oifname "${bridge}" ct state != { established, related } counter drop
        }
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr 10.231.0.0/16 oifname != "${bridge}" masquerade
        }
      '';
    };
    systemd.services.max-sandbox-network = {
      description = "Max native sandbox bridge";
      partOf = [ "max-stack.target" ];
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      before = [ "max-runtime.service" ];
      path = [
        pkgs.iproute2
        pkgs.nftables
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        nft list table inet max-sandbox >/dev/null
        # Prepare iproute2's shared namespace directory before other daemons
        # bind namespaces beneath it; a later overmount would hide their mounts.
        mkdir -p /run/netns
        if ! mountpoint -q /run/netns; then
          mount --bind /run/netns /run/netns
        fi
        mount --make-shared /run/netns
        if ! ip link show dev ${bridge} >/dev/null 2>&1; then
          ip link add name ${bridge} type bridge
        fi
        ip link set dev ${bridge} type bridge stp_state 0
        ip address replace 10.231.0.1/16 dev ${bridge}
        ip link set dev ${bridge} up
      '';
      # Do not remove a bridge beneath live instances during unit updates.
    };
    systemd.services.max = {
      requires = [ "max-sandbox-network.service" ];
      after = [ "max-sandbox-network.service" ];
    };
    # Coexist with unrelated Docker workloads without changing its global
    # FORWARD policy. The earlier nftables chain still filters public egress.
    systemd.services.max-sandbox-docker-network = lib.mkIf config.virtualisation.docker.enable {
      description = "Max native bridge coexistence with Docker forwarding";
      wantedBy = [
        "docker.service"
        "max-stack.target"
      ];
      partOf = [
        "docker.service"
        "max-stack.target"
      ];
      after = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # This separate unit avoids restarting the Docker daemon to add rules.
      script = ''
        ${pkgs.iptables}/bin/iptables -w -C DOCKER-USER -i ${bridge} -j ACCEPT 2>/dev/null || \
          ${pkgs.iptables}/bin/iptables -w -I DOCKER-USER 1 -i ${bridge} -j ACCEPT
        ${pkgs.iptables}/bin/iptables -w -C DOCKER-USER -o ${bridge} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
          ${pkgs.iptables}/bin/iptables -w -I DOCKER-USER 1 -o ${bridge} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      '';
    };
  };
}
