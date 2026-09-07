{ nixpkgs, maxModule, system }:
let
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = pkgs.writeShellScriptBin "max" ''exec ${pkgs.coreutils}/bin/sleep infinity'';
  napcatFixture = pkgs.writeShellScriptBin "max-napcat" ''exec ${pkgs.coreutils}/bin/sleep infinity'';
in
pkgs.testers.runNixOSTest {
  name = "max-state-migration";
  nodes.machine = { config, lib, ... }: {
    imports = [ maxModule ];
    system.stateVersion = "26.05";
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.postgresql pkgs.jq ];
    services.postgresql = {
      enable = true;
      ensureDatabases = lib.mkIf (!config.services.max.enable) [ "max-bot" ];
      ensureUsers = lib.mkIf (!config.services.max.enable) [ { name = "max-bot"; ensureDBOwnership = true; } ];
    };
    users.users.max-bot = lib.mkIf (!config.services.max.enable) {
      isSystemUser = true;
      group = "max-bot";
      home = "/var/lib/max-bot";
    };
    users.groups.max-bot = lib.mkIf (!config.services.max.enable) { };
    users.users.max-napcat = { isSystemUser = true; group = "max-napcat"; };
    users.groups.max-napcat = { };
    systemd.services.max = lib.mkIf (!config.services.max.enable) {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { User = "max-bot"; ExecStart = "${fixture}/bin/max"; };
    };
    services.max = {
      package = fixture;
      sandbox.enable = false;
      sandboxNetwork.enable = false;
      browser.enable = false;
    };
    specialisation.migrated.configuration.services.max = {
      enable = true;
      settings = { admin.port = 7700; };
      napcat = {
        enable = true;
        package = napcatFixture;
        qq = "12345";
        accessTokenFile = "/run/napcat-token";
      };
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("max.service")
    machine.wait_for_unit("postgresql.service")
    machine.succeed("install -d -m700 -o max-bot -g max-bot /var/lib/max-bot /var/lib/max-bot/images /var/lib/max-bot/napcat")
    machine.succeed("install -d -m700 -o max-napcat -g max-napcat /var/lib/max-bot/napcat/QQ /var/lib/max-bot/napcat/config")
    machine.succeed("install -d -m700 /var/lib/max-runtime/{roots,instances,migration-backups,volumes/max-sb-1-s1-data/work}")
    machine.succeed("echo media > /var/lib/max-bot/images/keep; echo account > /var/lib/max-bot/napcat/QQ/keep; echo work > /var/lib/max-runtime/volumes/max-sb-1-s1-data/work/keep")
    machine.succeed("echo legacy-secret > /var/lib/max-bot/max.yaml; echo legacy-env > /var/lib/max-bot/max-bot.env; echo fixture-token > /run/napcat-token; chmod 600 /run/napcat-token")
    machine.succeed("runuser -u max-bot -- psql -v ON_ERROR_STOP=1 -d max-bot -c \"CREATE TABLE images(local_path text); CREATE TABLE videos(local_path text); CREATE TABLE group_files(local_path text); INSERT INTO images VALUES ('/var/lib/max-bot/images/keep'),('images/relative');\"")
    uid = machine.succeed("id -u max-bot").strip()
    gid = machine.succeed("id -g max-bot").strip()
    database_oid = machine.succeed("runuser -u postgres -- psql -Atc \"SELECT oid FROM pg_database WHERE datname='max-bot'\"").strip()
    migrate = "bash ${../../scripts/migrate-max-state.sh}"
    machine.succeed(migrate + " --check")
    machine.fail(migrate + " --migrate")
    machine.succeed("systemctl stop max.service")
    machine.succeed(migrate + " --migrate")
    assert machine.succeed("id -u max").strip() == uid
    assert machine.succeed("id -g max").strip() == gid
    assert machine.succeed("runuser -u postgres -- psql -Atc \"SELECT oid FROM pg_database WHERE datname='max'\"").strip() == database_oid
    machine.succeed("/run/current-system/specialisation/migrated/bin/switch-to-configuration test")
    machine.succeed("systemctl start max-stack.target")
    machine.wait_for_unit("max.service")
    machine.wait_for_unit("max-napcat.service")
    assert machine.succeed("systemctl show max -p User --value").strip() == "max"
    assert machine.succeed("id -u max").strip() == uid
    assert machine.succeed("id -g max").strip() == gid
    assert machine.succeed("runuser -u max -- psql -At -d max -c 'SELECT current_user'").strip() == "max"
    paths = machine.succeed("runuser -u max -- psql -At -d max -c 'SELECT local_path FROM images ORDER BY local_path'").splitlines()
    assert set(paths) == {"/var/lib/max/app/images/keep", "images/relative"}, paths
    machine.succeed("grep -qx media /var/lib/max/app/images/keep; grep -qx account /var/lib/max/napcat/QQ/keep; grep -qx work /var/lib/max/runtime/volumes/max-sb-1-s1-data/work/keep")
    machine.fail("test -e /var/lib/max-bot")
    machine.fail("test -e /var/lib/max-runtime")
    machine.fail("test -e /var/lib/max/app/max.yaml")
    machine.succeed("runuser -u max -- jq -e '.admin.port == 7700' /etc/max/config.json")
    machine.succeed("jq -e '.network.websocketClients[0].token == \"fixture-token\"' /var/lib/max/napcat/config/onebot11_12345.json")
    machine.fail("runuser -u max -- ls /var/lib/max/napcat/QQ")
    machine.fail("runuser -u max -- ls /var/lib/max/runtime")
    machine.succeed("backup=$(cat /var/lib/max/backups/latest-state-migration); test -f $backup/complete; pg_restore --list $backup/max-bot.dump > /dev/null; grep -qx legacy-secret $backup/legacy-config/max.yaml")
  '';
}
