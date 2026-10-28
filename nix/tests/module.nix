# The module on a fresh machine, without any platform: Postgres comes up
# with the role and the database, max migrates and waits, and it stops
# cleanly when asked.
{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "max-module";
  nodes.machine = {
    imports = [ module ];
    services.maxx.enable = true;
    # tank's cluster, which maxx shares.
    services.postgresql.package = pkgs.postgresql_16;
  };
  testScript = ''
    machine.wait_for_unit("maxx.service")
    machine.wait_until_succeeds("journalctl -u maxx.service | grep -q 'migrations applied'")
    machine.succeed(
        "runuser -u postgres -- psql -d maxx -tAc "
        + "'select count(*) > 0 from _sqlx_migrations' | grep -qx t"
    )
    machine.succeed("systemctl stop maxx.service")
    machine.succeed("journalctl -u maxx.service | grep -q stopping")
    assert machine.succeed("systemctl show -P Result maxx.service").strip() == "success"
  '';
}
