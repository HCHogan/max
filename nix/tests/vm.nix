# The groups' VMs on one machine, nested: the module makes the taps, the
# firewall's rules and the service's sandbox, and vm-check boots the
# flake's guest the way max does, runs a command in it, runs a program
# whose history reaches the database through the MCP service, one that
# opens a page in the browser and saves a screenshot to /work, loads an
# extension into the browser by Max's flags, shows the model a video
# ffmpeg made, calls the MCP service with maxx from a command, and keeps a
# unit in
# /work/.max/systemd, which the next boot starts again, and wakes Max with
# max-wake. Then a VM on the operations network reaches a stand-in for the
# tailnet through its namespace, where an ordinary VM can't, its ip rule
# having outlived networkd.
{
  pkgs,
  module,
  newer,
}:
let
  # A unit Max might keep in a VM: it asks the VM service how it is, at
  # the port every program reaches max by, and notes the answer's status
  # with the boot it runs in and the image the guest is on (`newer` has
  # /etc/max-image).
  probe = pkgs.writeText "probe.sh" ''
    while true; do
      code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'content-type: application/json' \
        -d '{"units":1}' http://127.0.0.1:7777/units || true)
      echo "$(cat /proc/sys/kernel/random/boot_id) $code $(cat /etc/max-image 2> /dev/null || echo first)" >> /work/probe.log
      sleep 1
    done
  '';
  probeUnit = pkgs.writeText "probe.service" ''
    [Service]
    ExecStart=/bin/sh /work/probe.sh
    Restart=always

    [Install]
    WantedBy=multi-user.target
  '';
in
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
        # No tailnet here: its client fails to log in, and the test puts a
        # stand-in where the tailnet would be.
        operations = {
          enable = true;
          slots = 1;
          loginServer = "http://127.0.0.1:9";
          domain = "tail.example";
        };
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
    # A deploy that brings a new image for the VMs.
    specialisation.newer.configuration.services.maxx.vm.guest = newer;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    # As on tank: networkd, which removes the ip rules its .network files
    # don't name, and eth1's names the operations network's.
    networking.useNetworkd = true;
    systemd.network.networks."40-eth1".routingPolicyRules = [
      {
        From = "10.236.0.0/24";
        Table = 236;
        Priority = 236;
      }
    ];
  };
  testScript = ''
    machine.wait_for_unit("maxx.service")
    machine.wait_until_succeeds("ip -br address show maxx-vm1 | grep -q 10.235.0.5/30")
    machine.succeed("systemctl start maxx-vm-check.service")
    shown = machine.succeed("journalctl -u maxx-vm-check.service -o cat")
    assert "exit status 0" in shown and "Linux max" in shown, shown
    assert '"mcp":"not_found"' in shown, shown
    # The page's accessibility tree, with refs.
    assert '"tree":"检查\\n' in shown and 'button \\"搜索\\" [ref=e4]' in shown, shown
    # The next program finds its tab as it left it.
    assert '"kept":"还在"' in shown, shown
    # The browser loads an extension by Max's own flags.
    assert "浏览器重启了" in shown and '"hello":"扩展在"' in shown, shown
    # The guest's ffmpeg made a clip and the model's copy of it, and
    # left it and a picture for the model in the call's directory; the
    # host read both from /work, and said what it couldn't show.
    assert '{"seconds":3}' in shown and '{"path":"/work/.max/check.png"}' in shown, shown
    assert "给模型看的视频：3 秒" in shown and "给模型看的图片" in shown, shown
    assert "/work/.max/check.txt wasn't shown: it isn't a PNG, JPEG, GIF or WebP that decodes" in shown, shown
    # maxx calls the MCP service from a command, as the program did, and
    # lists the tools.
    assert " (not_found)\nmaxx 退出码 1\n1\n" in shown, shown
    # A background command is a unit of the guest's: the call comes back
    # with its name at once, its output is in its file while it runs, and
    # the guest tells of its end.
    assert "It runs in the background as max-job-" in shown, shown
    assert "后台命令结束的通知：[max-job-" in shown and "exit status 0, ran for" in shown, shown
    # A background agent is one too: pi in the guest, its model calls
    # through max, and its report from the guest.
    assert "max-agent-1 started in /work, for at most 6 hours." in shown, shown
    assert "后台 agent 的报告：[max-agent-1 完成] 检查\nvm-check 的 agent 说完了" in shown, shown
    assert "后台 agent 的模型调用：1 次，写了 7 tokens" in shown, shown
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
    assert "This chat's VM stays on" in shown, shown
    assert "后台起了\n1\nvm-check 收到了" in shown and "叫醒：vm-check 叫醒了自己" in shown, shown
    # The next boot starts it before vm-check runs max-units.
    machine.succeed("systemctl start maxx-vm-check.service")
    again = machine.succeed("journalctl -u maxx-vm-check.service -o cat")
    assert "开机时：active" in again and "记下了 2 次开机" in again, again
    # vm-check's VM was a unit of its own, and vm-check stopped it.
    machine.fail("systemctl is-active maxx-vm@check-0.service")

    # A VM outlives max. Conversation 7 has a unit, so max keeps its VM
    # on: the unit asks the VM service how it is every second, and notes
    # the answer with the boot it runs in.
    work = "/var/lib/maxx/vm/7/work"
    machine.succeed(
        f"install -d -o maxx -g maxx -m 700 /var/lib/maxx/vm/7 {work} {work}/.max {work}/.max/systemd",
        f"install -o maxx -g maxx -m 644 ${probeUnit} {work}/.max/systemd/probe.service",
        f"install -o maxx -g maxx -m 755 ${probe} {work}/probe.sh",
        "systemctl restart maxx.service",
    )
    machine.wait_until_succeeds("systemctl is-active maxx-vm@7.service", timeout=120)
    machine.wait_until_succeeds(f"grep -q ' 200 first$' {work}/probe.log", timeout=180)
    last = f"tail -n 1 {work}/probe.log"
    pid = machine.succeed("systemctl show -P MainPID maxx-vm@7.service").strip()
    boot = machine.succeed(f"{last} | cut -d' ' -f1").strip()
    # What the VM booted is rooted for as long as it runs.
    machine.succeed("readlink /nix/var/nix/gcroots/per-user/maxx/7 | grep -q max-guest.json")
    # While max is away the guest is told so, and the VM runs on.
    machine.succeed("systemctl stop maxx.service")
    machine.wait_until_succeeds(f"{last} | grep -q ' 503 first$'", timeout=60)
    machine.succeed("systemctl is-active maxx-vm@7.service")
    # The max that comes back attaches to it: the guest reaches it at the
    # socket bound again, in the same boot of the same VM.
    machine.succeed("systemctl start maxx.service")
    machine.wait_until_succeeds(
        "journalctl -u maxx.service -o cat | grep -q 'attached to a VM that runs'", timeout=120
    )
    machine.wait_until_succeeds(f"{last} | grep -q ' 200 first$'", timeout=120)
    assert machine.succeed("systemctl show -P MainPID maxx-vm@7.service").strip() == pid
    assert machine.succeed(f"{last} | cut -d' ' -f1").strip() == boot
    # A deploy brings a new image. max restarts with it and the VM's unit
    # is left; the max that comes back has the guest switch to the new
    # system where it runs, and the unit in it runs on through that.
    print(machine.succeed("/run/current-system/specialisation/newer/bin/switch-to-configuration test 2>&1"))
    machine.wait_until_succeeds(
        "journalctl -u maxx.service -o cat | grep -q \"a VM's guest is switched to the image max boots\"",
        timeout=600,
    )
    machine.wait_until_succeeds(f"{last} | grep -q ' 200 newer$'", timeout=120)
    assert machine.succeed("systemctl show -P MainPID maxx-vm@7.service").strip() == pid
    assert machine.succeed(f"{last} | cut -d' ' -f1").strip() == boot
    # Both images are rooted: the one it booted, whose kernel it runs,
    # and the one it is on.
    roots = machine.succeed("readlink /nix/var/nix/gcroots/per-user/maxx/7 /nix/var/nix/gcroots/per-user/maxx/7.now").split()
    assert len(set(roots)) == 2 and all("max-guest.json" in root for root in roots), roots
    assert "stale=false" in machine.succeed(
        "journalctl -u maxx.service -o cat | grep \"a VM's guest is switched\""
    )
    # A VM whose guest keeps another contract is restarted at once.
    machine.succeed(
        "systemctl stop maxx.service",
        "sed -i 's/\"contract\":[0-9]*/\"contract\":0/' /var/lib/maxx/vm/7/boot.json",
        "systemctl start maxx.service",
    )
    machine.wait_until_succeeds(
        "journalctl -u maxx.service -o cat | grep -q \"can't be attached to\"", timeout=120
    )
    machine.wait_until_succeeds(
        f"test \"$({last} | cut -d' ' -f1)\" != {boot} && {last} | grep -q ' 200 newer$'", timeout=240
    )
    assert machine.succeed("systemctl show -P MainPID maxx-vm@7.service").strip() != pid
    # Without its unit the VM isn't kept, and a stopped one's root goes.
    machine.succeed(
        "systemctl stop maxx.service",
        f"rm -rf {work}/.max/systemd",
        "systemctl stop maxx-vm@7.service",
        "systemctl start maxx.service",
    )
    machine.wait_for_unit("maxx.service")
    # The screenshot, among the test's outputs.
    machine.succeed("head -c 8 /var/lib/maxx/vm/check/0/work/.max/browser-check.png | grep -q PNG")
    machine.copy_from_vm("/var/lib/maxx/vm/check/0/work/.max/browser-check.png")
    print(shown)

    # The operations network. The tailnet's stand-in: a namespace behind a
    # veth from maxx-ops, where tailscale0 would be.
    machine.wait_for_unit("maxx-ops-network.service")
    machine.succeed("systemctl stop maxx-ops-tailscaled.service")
    # The rule that sends the VMs into the namespace outlives networkd
    # configuring a link, when it removes rules no .network names (a
    # stranger's goes), and the namespace's service adding it again.
    rules = "ip rule | grep -c 'from 10.236.0.0/24 lookup 236 proto static'"
    for again in ["", "systemctl restart maxx-ops-network.service"]:
        if again:
            machine.succeed(again)
        machine.succeed("ip rule add from 192.0.2.0/24 lookup 237 priority 237")
        machine.succeed("networkctl reconfigure eth1")
        machine.wait_until_fails("ip rule | grep -q 'lookup 237'")
        assert machine.succeed(rules) == "1\n", machine.succeed("ip rule")
    machine.succeed(
        "ip netns add fleet",
        "ip -n maxx-ops link add fleet0 type veth peer name eth0 netns fleet",
        "ip -n maxx-ops address add 100.64.0.1/24 dev fleet0",
        "ip -n maxx-ops link set fleet0 up",
        "ip -n maxx-ops route add 100.64.0.0/10 dev fleet0",
        "ip -n fleet address add 100.64.0.2/24 dev eth0",
        "ip -n fleet link set eth0 up",
        "ip -n fleet link set lo up",
    )
    machine.succeed("ip rule | grep -q 'from 10.236.0.0/24 lookup 236'")
    check = (
        "systemd-run --wait --collect --pipe -p User=maxx -p Group=maxx -p SupplementaryGroups=kvm "
        + "$(systemctl show -P ExecStart maxx-vm-check.service | grep -o '/nix/store/[^ ;]*/bin/max vm-check --config [^ ;]*') "
    )
    reached = machine.succeed(
        check + "--operations --command 'cat /run/max/ssh_config; head -n 1 /etc/resolv.conf; ping -c 1 -W 5 100.64.0.2' 2>&1"
    )
    assert "HostName %h.tail.example" in reached and "User max" in reached, reached
    assert "nameserver 100.100.100.100" in reached, reached
    assert "1 received" in reached, reached
    # An ordinary VM can't, nor has the ssh_config.
    refused = machine.succeed(
        check + "--command 'ls /run/max/ssh_config; ping -c 1 -W 5 100.64.0.2' 2>&1"
    )
    assert "No such file" in refused and "0 received" in refused, refused
    print(reached)
  '';
}
