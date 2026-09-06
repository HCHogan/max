# Public egress for command sandboxes. Keep filtering separate from Docker's
# own tables so its NAT and bridge management cannot overwrite this policy.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.max;
  network = "max-sandbox";
  bridge = "max-sb-egress";
in
{
  options.services.max.sandboxNetwork.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Provision the fixed Max command-sandbox network and public IPv4 egress
      policy. Disable only when an equivalent network is managed externally.
      Missing network provisioning makes sandbox creation fail closed.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.sandboxNetwork.enable) {
    assertions = [{
      assertion = config.networking.nftables.enable;
      message = "Max sandbox public egress requires nftables filtering.";
    }];
    networking.nftables.enable = lib.mkDefault true;
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
          iifname "${bridge}" ip daddr @non_public_v4 counter reject with icmpx type admin-prohibited
          oifname "${bridge}" ct state != { established, related } counter drop
        }
      '';
    };

    systemd.services.max-sandbox-network = {
      description = "Max sandbox public-egress network";
      requires = [ "docker.service" "nftables.service" ];
      after = [ "docker.service" "nftables.service" ];
      before = [ "max.service" ];
      path = [ config.virtualisation.docker.package pkgs.nftables pkgs.jq ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        nft list table inet max-sandbox >/dev/null
        # List first: an inspection/daemon error must not masquerade as absence.
        existing=$(docker network ls --filter name='^${network}$' --format '{{.Name}}')
        if [ -z "$existing" ]; then
          docker network create --driver bridge --ipv6=false \
            --opt com.docker.network.bridge.name=${bridge} \
            --opt com.docker.network.bridge.enable_icc=false \
            --label max.sandbox.network-policy=public-v1 ${network}
        fi
        docker network inspect ${network} | jq -e '
          length == 1 and (.[0] |
            .Driver == "bridge" and .Internal == false and .EnableIPv6 == false and
            .Options["com.docker.network.bridge.name"] == "${bridge}" and
            .Options["com.docker.network.bridge.enable_icc"] == "false" and
            .Labels["max.sandbox.network-policy"] == "public-v1")
        ' >/dev/null
      '';
    };

    systemd.services.max = {
      requires = [ "max-sandbox-network.service" ];
      after = [ "max-sandbox-network.service" ];
    };
  };
}
