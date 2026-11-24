# The module on a fresh machine, without any platform: max's own Postgres
# comes up with the role and the database, max migrates and waits, and it
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
  };
  testScript =
    { nodes, ... }:
    ''
      machine.wait_for_unit("maxx.service")
      machine.wait_until_succeeds("journalctl -u maxx.service | grep -q 'migrations applied'")

      def sql(query):
          return machine.succeed(
              f"maxx-psql --no-psqlrc --tuples-only --no-align --command=\"{query}\""
          ).strip()

      assert sql("select count(*) > 0 from _sqlx_migrations") == "t"
      # maxx's role isn't a superuser, and the migrations need none: the
      # extensions they create, pg_trgm and btree_gist, are trusted ones.
      assert sql("select rolsuper from pg_roles where rolname = 'maxx'") == "f"
      assert sql("select datlocprovider::text || datlocale from pg_database where datname = 'maxx'") == "bC.UTF-8"
      # The cluster is on its socket alone, and lets in only the users with
      # a role of their name.
      machine.fail("ss -Hltn | grep -q ':5432 '")
      machine.fail(
          "runuser -u nobody -- ${nodes.machine.services.maxx.postgresql.package}/bin/psql "
          + "--host=/run/maxx-postgres --dbname=maxx --command='select 1'"
      )

      machine.succeed("systemctl stop maxx.service")
      machine.succeed("journalctl -u maxx.service | grep -q stopping")
      assert machine.succeed("systemctl show -P Result maxx.service").strip() == "success"
    '';
}
