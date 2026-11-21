# The groups' VMs on one machine, nested: the module makes the taps, the
# firewall's rules and the service's sandbox, and vm-check boots the
# flake's guest the way max does, runs a command in it, runs a program
# whose history reaches the database through max's service, one that
# opens a page in the browser and saves a screenshot to /work, loads an
# extension into the browser by Max's flags, shows the model a video
# ffmpeg made, calls max's service with maxx from a command, and keeps a
# unit in
# /work/.max/systemd, which the next boot starts again, and wakes Max with
# maxx wake. A VM outlives max: its port for the host is a link to max's
# socket, which is systemd's, so what the guest asks of max while max
# restarts waits there, and max knows whose VM a call is from by the
# process that made its connection. A model's answer streams to the guest
# through max. Then a VM on the
# operations network reaches a stand-in for the tailnet through its
# namespace, where an ordinary VM can't, its ip rule having outlived
# networkd; the machine itself by its tailnet address the same way; and
# the namespace's client keeps its resolvers when resolved rewrites its
# stub.
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
      code=$(curl -s -m 60 -o /dev/null -w '%{http_code}' -H 'content-type: application/json' \
        -d '{"units":1}' http://127.0.0.1:7777/units || true)
      echo "$(cat /proc/sys/kernel/random/boot_id) $code $(cat /etc/max-image 2> /dev/null || echo first)" >> /work/probe.log
      sleep 1
    done
  '';
  # A model for the background agents that takes its time: eight pieces,
  # a second apart.
  slow = pkgs.writeText "slow.py" ''
    import http.server, time

    class Model(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("content-length", 0)))
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            for n in range(8):
                piece = '{"choices":[{"index":0,"delta":{"content":"piece %d"}}]}' % n
                self.wfile.write(b"data: " + piece.encode() + b"\n\n")
                self.wfile.flush()
                time.sleep(1)
            self.wfile.write(b"data: [DONE]\n\n")

    http.server.ThreadingHTTPServer(("127.0.0.1", 9100), Model).serve_forever()
  '';
  # A program in a VM that asks it for an answer, and keeps what comes.
  asks = pkgs.writeText "asks.sh" ''
    curl -sN -m 60 -H 'content-type: application/json' \
      -d '{"model": "slow/slow", "stream": true, "messages": []}' \
      http://127.0.0.1:7777/llm/chat/completions > /work/answer.txt 2>&1
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
          # The machine's own tailnet address, as tank's is; the test puts
          # it on the machine and on the tailnet's stand-in.
          hostAddress = "100.64.0.9";
        };
      };
      settings = {
        vm = {
          cpus = 2;
          memory_mib = 1024;
          disk_gib = 2;
        };
        # Never called: nothing here triggers a turn. The agents' model
        # is, by a program in a VM: the slow one above.
        llm = {
          default.model = "local/small";
          intent.model = "local/small";
          job.model = "slow/slow";
          providers.local = {
            base_url = "http://127.0.0.1:9/v1";
            protocol = "chat";
            models.small.context_window = 32768;
          };
          providers.slow = {
            base_url = "http://127.0.0.1:9100/v1";
            protocol = "chat";
            models.slow.context_window = 32768;
          };
        };
      };
    };
    services.postgresql.package = pkgs.postgresql_16;
    systemd.services.slow-model = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${slow}";
    };
    # A deploy that brings a new image for the VMs.
    specialisation.newer.configuration.services.maxx.vm.guest = newer;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    # As on tank: networkd, which removes the ip rules its .network files
    # don't name, and eth1's names the operations network's; and resolved,
    # whose stub /etc/resolv.conf leads to.
    networking.useNetworkd = true;
    services.resolved.enable = true;
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
    assert '"history":"not_found"' in shown, shown
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
    # maxx calls max's service from a command, as the program did, and
    # lists the tools.
    assert " (not_found)\nmaxx 退出码 1\n1\n" in shown, shown
    # What /status asks of a guest: its NixOS and its memory, and how its
    # systemd has the unit of Max's.
    assert "客户机：NixOS 2" in shown and "unit：boot-note.service loaded exited" in shown, shown
    # A call max lets go of, as a killed turn's, closes its channel, and
    # the guest stops its unit: nothing of it runs for the call after.
    assert "放手的调用跑起来过 1 个，还剩 0 个" in shown, shown
    # A background command is a unit of the guest's: the call comes back
    # with its name at once, its output is in its file while it runs, and
    # the guest tells of its end.
    assert "It runs in the background as max-job-" in shown, shown
    assert "后台命令结束的通知：[max-job-" in shown and "exit status 0, ran for" in shown, shown
    # A background agent is one too: the guest's pi, its model calls
    # through max, and its last words in the notice.
    assert "后台 agent 的报告：[max-job-" in shown and "完成] $ pi -p --no-session" in shown, shown
    assert "vm-check 的 agent 说完了" in shown, shown
    assert "后台 agent 的模型调用：1 次\n" in shown, shown
    # A unit in /work/.max/systemd, started by maxx units apply, with the
    # system's commands on its PATH.
    assert "boot-note.service：active" in shown, shown
    assert "开机时：inactive" in shown and "记下了 1 次开机" in shown, shown
    # Commands and units have /work for a home, and the login shell's PATH
    # is built from it.
    assert "家：/work，unit 的家：/work" in shown and "PATH 里有家里的 profile" in shown, shown
    # maxx units apply tells the VM service, which keeps the VM on; maxx wake, from
    # the background command, calls as a program and reaches vm-check,
    # standing in for the group's actor.
    assert "This chat's VM stays on" in shown, shown
    assert "后台起了\n1\nvm-check 收到了" in shown and "叫醒：vm-check 叫醒了自己" in shown, shown
    # The next boot starts it before vm-check runs maxx units apply.
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
        f"install -o maxx -g maxx -m 755 ${asks} {work}/asks.sh",
        "systemctl restart maxx.service",
    )
    machine.wait_until_succeeds("systemctl is-active maxx-vm@7.service", timeout=120)
    machine.wait_until_succeeds(f"grep -q ' 200 first$' {work}/probe.log", timeout=180)
    last = f"tail -n 1 {work}/probe.log"

    def back(condition, timeout):
        # When the unit doesn't come up, what the guest's boot made of it:
        # this failed twice on 2026-11-14 and not again, with nothing to
        # go by.
        try:
            machine.wait_until_succeeds(condition, timeout=timeout)
        except Exception:
            print(machine.execute(f"tail -n 3 {work}/probe.log")[1])
            said = "systemctl status max-units.service probe.service --no-pager -l; journalctl -b -u max-units.service --no-pager; ls -la /work/.max/systemd /run/max/units"
            print(machine.execute(f"timeout 60 maxx-ssh 7 '{said}' < /dev/null 2>&1")[1])
            raise

    pid = machine.succeed("systemctl show -P MainPID maxx-vm@7.service").strip()
    boot = machine.succeed(f"{last} | cut -d' ' -f1").strip()
    # The VM is a machine of the host's, by its unit, and root gets into
    # it as max does.
    assert machine.succeed("machinectl list --no-legend").split()[:3] == ["maxx-7", "vm", "maxx"]
    machined = machine.succeed("machinectl show maxx-7 -p Unit -p Leader").split()
    assert sorted(machined) == [f"Leader={pid}", "Unit=maxx-vm@7.service"], machined
    assert machine.succeed("maxx-ssh 7 'hostname; id -un; pwd' < /dev/null").split() == ["max", "root", "/work"]
    # What the VM booted is rooted for as long as it runs.
    machine.succeed("readlink /nix/var/nix/gcroots/per-user/maxx/7 | grep -q max-guest.json")
    # Where the guest reaches the host is a link to max's socket, and max
    # took every call there for a VM's: the unit's 200s are conversation
    # 7's, which systemd says the process at the other end is of.
    assert machine.succeed("readlink /var/lib/maxx/vm/7/notify.vsock_7777").strip() == "../max.sock"
    machine.fail("journalctl -u maxx.service -u maxx-vm-check.service -o cat | grep \"that no VM's process made\"")
    # max restarts, as at a deploy. The socket the guests reach it at is
    # systemd's, which goes on listening: what the unit asks meanwhile
    # waits there, and the max that comes attaches to the VM and answers.
    # Nothing in the guest hears of it: every answer is a 200, in the same
    # boot of the same VM.
    machine.succeed("systemctl is-active maxx.socket")
    # It is systemd's socket max listens at, and no other of max's own in
    # its place.
    machine.succeed("journalctl -u maxx.service -o cat | grep -q 'listening at the socket systemd gave max'")
    assert machine.succeed("ss -xl | grep -c /var/lib/maxx/vm/max.sock").strip() == "1"
    before = machine.succeed("systemctl show -P MainPID maxx.service").strip()
    asked = int(machine.succeed(f"wc -l < {work}/probe.log"))
    machine.succeed("systemctl restart maxx.service")
    machine.wait_until_succeeds(
        "journalctl -u maxx.service -o cat | grep -q 'attached to a VM that runs'", timeout=120
    )
    machine.wait_until_succeeds(f"test $(wc -l < {work}/probe.log) -gt {asked + 3}", timeout=120)
    assert machine.succeed("systemctl show -P MainPID maxx.service").strip() != before
    since = machine.succeed(f"tail -n +{asked + 1} {work}/probe.log").splitlines()
    assert all(line.split()[1] == "200" for line in since), since
    assert machine.succeed("systemctl show -P MainPID maxx-vm@7.service").strip() == pid
    assert machine.succeed(f"{last} | cut -d' ' -f1").strip() == boot
    # Stopped alone, max is started by the next thing the unit asks, which
    # waits at the socket for it: nothing but 200s again.
    before = machine.succeed("systemctl show -P MainPID maxx.service").strip()
    asked = int(machine.succeed(f"wc -l < {work}/probe.log"))
    machine.succeed("systemctl stop maxx.service")
    machine.wait_until_succeeds(f"test $(wc -l < {work}/probe.log) -gt {asked + 3}", timeout=120)
    assert machine.succeed("systemctl show -P MainPID maxx.service").strip() not in ("0", before)
    since = machine.succeed(f"tail -n +{asked + 1} {work}/probe.log").splitlines()
    assert all(line.split()[1] == "200" for line in since), since
    # max says what the models are, and a program in the VM asks the
    # agents' model through it for an answer that takes eight seconds to
    # come: it comes as it is said, and whole.
    assert machine.succeed("maxx-ssh 7 'curl -s -m 10 http://127.0.0.1:7777/llm | jq -r .model' < /dev/null").strip() == "slow/slow"
    machine.succeed("maxx-ssh 7 'systemd-run --collect --unit=asks /bin/sh /work/asks.sh' < /dev/null")
    machine.wait_until_succeeds(f"grep -q 'piece 0' {work}/answer.txt", timeout=30)
    machine.wait_until_succeeds(f"grep -q 'DONE' {work}/answer.txt", timeout=60)
    answer = machine.succeed(f"cat {work}/answer.txt")
    assert answer.count("piece ") == 8, answer
    # Stopped with its socket, max isn't there to wait for: nothing
    # listens where the guest's port leads, its connection only closes,
    # and the VM runs on. (With the socket left, the next thing the unit
    # asked would start max again.)
    machine.succeed("systemctl stop maxx.socket maxx.service")
    machine.wait_until_succeeds(f"{last} | grep -q ' 000 first$'", timeout=60)
    machine.succeed("systemctl is-active maxx-vm@7.service")
    # The max that comes back, its socket with it, attaches to the VM
    # again.
    machine.succeed("systemctl start maxx.service")
    machine.succeed("systemctl is-active maxx.socket")
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
    roots = machine.succeed("readlink /nix/var/nix/gcroots/per-user/maxx/7 /nix/var/nix/gcroots/per-user/maxx/7.*").split()
    assert len(set(roots)) == 2 and all("max-guest.json" in root for root in roots), roots
    assert "stale=false" in machine.succeed(
        "journalctl -u maxx.service -o cat | grep \"a VM's guest is switched\""
    )
    # The guest reboots itself; its kernel's panic is the same reset to
    # the host. cloud-hypervisor would boot it again in place, with no
    # virtiofsd left to serve it, so the launcher ends the VM at once. max
    # finds the unit ended at its next sweep, without a wait on its
    # socket, and boots the VM again, being kept.
    machine.execute("timeout 30 maxx-ssh 7 'systemctl reboot' < /dev/null")
    machine.wait_until_succeeds(
        "journalctl -u maxx-vm@7.service -o cat | grep -q 'virtiofsd ended'", timeout=60
    )
    machine.wait_until_fails("systemctl is-active maxx-vm@7.service", timeout=10)
    machine.wait_until_succeeds(
        "journalctl -u maxx.service -o cat | grep -q 'a VM that ran has ended by itself'", timeout=120
    )
    back(f"test \"$({last} | cut -d' ' -f1)\" != {boot} && {last} | grep -q ' 200 newer$'", 300)
    assert "couldn't attach to a VM" not in machine.succeed("journalctl -u maxx.service -o cat")
    pid = machine.succeed("systemctl show -P MainPID maxx-vm@7.service").strip()
    boot = machine.succeed(f"{last} | cut -d' ' -f1").strip()
    # The machine is the boot that runs now.
    assert machine.succeed("machinectl show maxx-7 -p Leader --value").strip() == pid
    # A VM whose guest keeps another contract is restarted at once.
    machine.succeed(
        "systemctl stop maxx.socket maxx.service",
        "sed -i 's/\"contract\":[0-9]*/\"contract\":0/' /var/lib/maxx/vm/7/boot.json",
        "systemctl start maxx.service",
    )
    machine.wait_until_succeeds(
        "journalctl -u maxx.service -o cat | grep -q \"can't be attached to\"", timeout=120
    )
    back(f"test \"$({last} | cut -d' ' -f1)\" != {boot} && {last} | grep -q ' 200 newer$'", 240)
    assert machine.succeed("systemctl show -P MainPID maxx-vm@7.service").strip() != pid
    # Without its unit the VM isn't kept, and a stopped one's root goes.
    machine.succeed(
        "systemctl stop maxx.socket maxx.service",
        f"rm -rf {work}/.max/systemd",
        "systemctl stop maxx-vm@7.service",
        "systemctl start maxx.service",
    )
    machine.wait_for_unit("maxx.service")
    machine.wait_until_fails("ls /nix/var/nix/gcroots/per-user/maxx/ | grep -q '^7'", timeout=60)
    # Nor is it a machine any more, or to be got into.
    machine.wait_until_fails("machinectl show maxx-7", timeout=30)
    machine.fail("maxx-ssh 7 true < /dev/null")
    # The screenshot, among the test's outputs.
    machine.succeed("head -c 8 /var/lib/maxx/vm/check/0/work/.max/browser-check.png | grep -q PNG")
    machine.copy_from_vm("/var/lib/maxx/vm/check/0/work/.max/browser-check.png")
    print(shown)

    # The operations network. The tailnet's stand-in: a namespace behind a
    # veth from maxx-ops, where tailscale0 would be.
    machine.wait_for_unit("maxx-ops-network.service")
    # Its client keeps the resolvers it was given when resolved renames a
    # new stub over the one /etc/resolv.conf leads to, as it does when
    # the host's DNS changes; the host's 127.0.0.53 isn't in the namespace.
    machine.succeed("test $(readlink -f /etc/resolv.conf) = /run/systemd/resolve/stub-resolv.conf")
    machine.wait_until_succeeds(
        "p=$(systemctl show -P MainPID maxx-ops-tailscaled.service) && test $p != 0"
        + " && i=$(stat -c %i /run/systemd/resolve/stub-resolv.conf)"
        + " && resolvectl domain eth1 renamed-$RANDOM.test && sleep 1"
        + " && test $(stat -c %i /run/systemd/resolve/stub-resolv.conf) != $i"
        + " && nsenter -t $p -m cat /etc/resolv.conf | grep -q '^nameserver 223.5.5.5'"
        + " && test $(systemctl show -P MainPID maxx-ops-tailscaled.service) = $p",
        timeout=120,
    )
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
        # The machine's own tailnet address: on the machine, as it would be
        # on its tailscale0, and on the tailnet, where its node answers.
        "ip link add tailnet0 type dummy",
        "ip address add 100.64.0.9/32 dev tailnet0",
        "ip link set tailnet0 up",
        "ip -n fleet address add 100.64.0.9/32 dev eth0",
        "ip -n fleet link set eth0 up",
        "ip -n fleet link set lo up",
    )
    machine.succeed("ip rule | grep -q 'from 10.236.0.0/24 lookup 236'")
    check = (
        "systemd-run --wait --collect --pipe -p User=maxx -p Group=maxx -p SupplementaryGroups=kvm "
        + "$(systemctl show -P ExecStart maxx-vm-check.service | grep -o '/nix/store/[^ ;]*/bin/max vm-check --config [^ ;]*') "
    )
    reached = machine.succeed(
        check + "--operations --command 'cat /run/max/ssh_config; head -n 1 /etc/resolv.conf;"
        + " ping -c 1 -W 5 100.64.0.2; ping -c 1 -W 5 100.64.0.9' 2>&1"
    )
    assert "HostName %h.tail.example" in reached and "User max" in reached, reached
    assert "nameserver 100.100.100.100" in reached, reached
    # Another machine, and this one by its tailnet address, through the
    # namespace: the machine itself refuses them.
    assert reached.count(" 1 received") == 2, reached
    # An ordinary VM can't, nor has the ssh_config.
    refused = machine.succeed(
        check + "--command 'ls /run/max/ssh_config; ping -c 1 -W 5 100.64.0.2' 2>&1"
    )
    assert "No such file" in refused and "0 received" in refused, refused
    print(reached)
  '';
}
