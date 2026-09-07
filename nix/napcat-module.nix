{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.max.napcat;
  state = "/var/lib/max/napcat";
in
{
  options.services.max.napcat = {
    enable = lib.mkEnableOption "native NapCat QQ client using napcat.nix";
    package = lib.mkOption {
      type = lib.types.package;
      default = import ./napcat.nix { inherit pkgs; };
      description = "Native NapCat launcher.";
    };
    qq = lib.mkOption {
      type = lib.types.strMatching "[0-9]+";
      default = "0";
      description = "QQ account for quick login; 0 selects at the web UI.";
    };
    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Runtime credentials, including NAPCAT_ACCESS_TOKEN matching Max's MAX_ACCESS_TOKEN.";
    };
    accessTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "OneBot token loaded as a systemd credential, matching Max's server.access_token.";
    };
    websocketPort = lib.mkOption {
      type = lib.types.port;
      default = 18080;
      description = "Max's loopback OneBot reverse WebSocket port.";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 6099;
      description = "Loopback-only NapCat web UI port.";
    };
  };
  config = lib.mkIf (config.services.max.enable && cfg.enable) {
    users.users.max-napcat = {
      isSystemUser = true;
      group = "max-napcat";
      extraGroups = [ "max-outbox" ];
    };
    users.groups.max-napcat = { };
    systemd.services.max.environment = {
      MAX_WS_HOST = lib.mkDefault "127.0.0.1";
      MAX_WS_PORT = lib.mkDefault (toString cfg.websocketPort);
    };
    systemd.tmpfiles.rules = [
      "d ${state} 0700 max-napcat max-napcat -"
      "d ${state}/QQ 0700 max-napcat max-napcat -"
      "d ${state}/config 0700 max-napcat max-napcat -"
      "d ${state}/outbox 0700 max-napcat max-napcat -"
    ];
    systemd.services.max-napcat = {
      description = "Max native NapCat QQ client";
      partOf = [ "max-stack.target" ];
      wantedBy = [ "max-stack.target" ];
      requires = [ "max-storage.service" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "max.service"
        "max-storage.service"
      ];
      path = [
        pkgs.jq
        pkgs.coreutils
      ];
      environment = {
        MAX_NAPCAT_QQ_DIR = "${state}/QQ";
        MAX_NAPCAT_CONFIG_DIR = "${state}/config";
        MAX_NAPCAT_OUTBOX_DIR = "${state}/outbox";
      };
      preStart = ''
        set -eu
        ${lib.optionalString (cfg.accessTokenFile != null) ''
          export NAPCAT_ACCESS_TOKEN="$(cat "$CREDENTIALS_DIRECTORY/access-token")"
        ''}
        config_file=${state}/config/onebot11_${cfg.qq}.json
        test -f "$config_file" || printf '{}' > "$config_file"
        # The token is read from the environment by jq, never a CLI argument
        # or a Nix store file. This module owns Max's OneBot connection.
        jq '.network = ((.network // {}) + {
          httpServers: [], httpSseServers: [], httpClients: [], websocketServers: [],
          websocketClients: [{name: "max", enable: true,
            url: "ws://127.0.0.1:${toString cfg.websocketPort}/onebot",
            messagePostFormat: "array", reportSelfMessage: false,
            token: (env.NAPCAT_ACCESS_TOKEN // ""), debug: false,
            reconnectInterval: 5000, heartInterval: 30000}]
        })' "$config_file" > "$config_file.tmp"
        chmod 600 "$config_file.tmp"
        mv "$config_file.tmp" "$config_file"
        webui=${state}/config/webui.json
        test -f "$webui" || printf '{}' > "$webui"
        jq '.host = "127.0.0.1" | .port = ${toString cfg.webuiPort}' "$webui" > "$webui.tmp"
        chmod 600 "$webui.tmp"
        mv "$webui.tmp" "$webui"
      '';
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/max-napcat -q ${cfg.qq}";
        User = "max-napcat";
        Group = "max-napcat";
        SupplementaryGroups = [ "max-outbox" ];
        Slice = "max.slice";
        StateDirectory = "max/napcat";
        StateDirectoryMode = "0700";
        WorkingDirectory = state;
        EnvironmentFile = cfg.environmentFiles;
        LoadCredential = lib.optional (cfg.accessTokenFile != null) "access-token:${cfg.accessTokenFile}";
        BindReadOnlyPaths = [ "/var/lib/max/app/var/outbox:${state}/outbox" ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        # bubblewrap mounts /proc for its new PID/user namespace. systemd's
        # /proc/sys overmounts prevent that mount (mount_too_revealing).
        # The unprivileged host uid and empty capabilities still deny writes
        # to host kernel tunables; bubblewrap supplies the inner isolation.
        ProtectKernelTunables = false;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        UMask = "0077";
        MemoryMax = "4G";
        TasksMax = 512;
        KillMode = "mixed";
        TimeoutStopSec = 30;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
