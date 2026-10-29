# The groups' VMs on one machine, nested: the module makes the taps, the
# firewall's rules and the service's sandbox, and vm-check boots the
# flake's guest the way max does, runs a command in it, runs a program
# whose context_read reaches the database through the MCP service, and one
# that opens a page in the browser and saves a screenshot to /work.
{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "max-vm";
  nodes.machine = {
    imports = [ module ];
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    services.maxx = {
      enable = true;
      vm = {
        enable = true;
        slots = 2;
      };
      settings = {
        vm = {
          cpus = 2;
          memory_mib = 1024;
          disk_gib = 2;
        };
        # Never called: nothing here triggers a turn.
        llm = {
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
    services.postgresql.package = pkgs.postgresql_16;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  };
  testScript = ''
    machine.wait_for_unit("maxx.service")
    machine.wait_until_succeeds("ip -br address show maxx-vm1 | grep -q 10.235.0.5/30")
    machine.succeed("systemctl start maxx-vm-check.service")
    shown = machine.succeed("journalctl -u maxx-vm-check.service -o cat")
    assert "退出码 0" in shown and "Linux max" in shown, shown
    assert '"mcp":"not_found"' in shown, shown
    assert '"title":"检查","elements":["body > input","#go"]' in shown, shown
    # The screenshot, among the test's outputs.
    machine.succeed("head -c 8 /var/lib/maxx/vm/0/work/.max/browser-check.png | grep -q PNG")
    machine.copy_from_vm("/var/lib/maxx/vm/0/work/.max/browser-check.png")
    print(shown)
  '';
}
