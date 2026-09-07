{ config, pkgs, lib, ... }:
{
  config = lib.mkIf config.services.max.enable {
    # DynamicUser stores state below /var/lib/private. Back that namespace
    # with Max's tree while retaining systemd's UID and directory isolation.
    systemd.services.max-storage = {
      description = "Max persistent storage";
      wantedBy = [ "max-stack.target" ];
      partOf = [ "max-stack.target" ];
      before = [ "max.service" "max-runtime.service" "max-napcat.service" ];
      path = [ pkgs.coreutils pkgs.util-linux ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        install -d -m 0755 /var/lib/max
        install -d -m 0700 /var/lib/max/private /var/lib/private /var/lib/private/max
        if ! mountpoint -q /var/lib/private/max; then
          test -z "$(ls -A /var/lib/private/max)"
          mount --bind /var/lib/max/private /var/lib/private/max
        fi
        test "$(stat -c '%d:%i' /var/lib/max/private)" = "$(stat -c '%d:%i' /var/lib/private/max)"
      '';
      # Keep the bind mount in place across unit upgrades and stack stops.
    };
  };
}
