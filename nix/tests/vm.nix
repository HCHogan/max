# The groups' VMs on one machine, nested: the module makes the taps, the
# firewall's rules and the service's sandbox, and vm-check boots the
# flake's guest the way max does, runs a command in it, runs a program
# whose history reaches the database through the MCP service, one that
# opens a page in the browser and saves a screenshot to /work, loads an
# extension into the browser by Max's flags, shows the model a video
# ffmpeg made, calls the MCP service with maxx from a command, and keeps a
# unit in
# /work/.max/systemd, which the next boot starts again, and wakes Max with
# max-wake.
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
    # The page's accessibility tree, with refs.
    assert '"tree":"检查\\n' in shown and 'button \\"搜索\\" [ref=e4]' in shown, shown
    # The next program finds its tab as it left it.
    assert '"kept":"还在"' in shown, shown
    # The browser loads an extension by Max's own flags.
    assert "浏览器重启了" in shown and '"hello":"扩展在"' in shown, shown
    # The guest's ffmpeg made a clip and the model's copy of it, whose
    # length the host read.
    assert '{"seconds":3}' in shown, shown
    # maxx calls the MCP service from a command, as the program did, and
    # lists the tools.
    assert "（not_found）\nmaxx 退出码 1\n1\n" in shown, shown
    # A background command's output is in its file while it runs.
    assert "后台命令：Done\n退出码 0，跑了" in shown, shown
    # A unit in /work/.max/systemd, started by max-units, with the
    # system's commands on its PATH.
    assert "boot-note.service：active" in shown, shown
    assert "开机时：inactive" in shown and "记下了 1 次开机" in shown, shown
    # Commands and units have /work for a home, and the login shell's PATH
    # is built from it.
    assert "家：/work，unit 的家：/work" in shown and "PATH 里有家里的 profile" in shown, shown
    # max-units tells the VM service, which keeps the VM on; max-wake, from
    # the background command, calls as a program and reaches vm-check,
    # standing in for the group's actor.
    assert "这个群的 VM 会一直开着" in shown, shown
    assert "后台起了\n1\nvm-check 收到了" in shown and "叫醒：vm-check 叫醒了自己" in shown, shown
    # The next boot starts it before vm-check runs max-units.
    machine.succeed("systemctl start maxx-vm-check.service")
    again = machine.succeed("journalctl -u maxx-vm-check.service -o cat")
    assert "开机时：active" in again and "记下了 2 次开机" in again, again
    # The screenshot, among the test's outputs.
    machine.succeed("head -c 8 /var/lib/maxx/vm/check/0/work/.max/browser-check.png | grep -q PNG")
    machine.copy_from_vm("/var/lib/maxx/vm/check/0/work/.max/browser-check.png")
    print(shown)
  '';
}
