# The module on a fresh machine, without any platform: Postgres comes up
# with the role, the database and pgvector, max migrates and waits, and it
# stops cleanly when asked.
{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "max-module";
  nodes.machine = {
    imports = [ module ];
    services.maxx = {
      enable = true;
      # Never called: nothing here triggers a turn.
      settings.llm = {
        default.model = "local/small";
        intent.model = "local/small";
        providers.local = {
          base_url = "http://127.0.0.1:9/v1";
          protocol = "chat";
          models.small.context_window = 32768;
        };
      };
    };
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
    # maxx's role isn't a superuser: the module made pgvector for it.
    machine.succeed(
        "runuser -u postgres -- psql -d maxx -tAc "
        + "\"select r.rolsuper from pg_roles r where r.rolname = 'maxx'\" | grep -qx f"
    )
    machine.succeed("runuser -u postgres -- psql -d maxx -tAc 'table caption_embeddings'")
    machine.succeed("systemctl stop maxx.service")
    machine.succeed("journalctl -u maxx.service | grep -q stopping")
    assert machine.succeed("systemctl show -P Result maxx.service").strip() == "success"
  '';
}
