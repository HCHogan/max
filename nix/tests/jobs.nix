# What Max runs in a guest, as units (nix/jobs.nix, nix/max-jobs.sh): a
# call's line, a background command's notice, and what becomes of each
# when it is stopped, when max is away, and when its caller is. The
# machine has the guest's jobs without a VM's shares; a fake /mcp at
# 127.0.0.1:7777 stands in for max, and keeps what wakes it.
{ pkgs }:
let
  host = pkgs.writeText "fake-max.js" ''
    const http = require("node:http");
    const fs = require("node:fs");
    const wake = { name: "wake", description: "Wakes Max.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } };
    http.createServer((req, res) => {
      let body = "";
      req.on("data", chunk => (body += chunk));
      req.on("end", () => {
        const { id, method, params } = JSON.parse(body);
        let result = {};
        if (method === "tools/list") result = { tools: [wake] };
        if (method === "tools/call") {
          fs.appendFileSync("/run/wakes", JSON.stringify(params.arguments.text) + "\n");
          result = { isError: false, structuredContent: { said: "woke Max" } };
        }
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id, result }));
      });
    }).listen(7777, "127.0.0.1");
  '';
in
pkgs.testers.runNixOSTest {
  name = "max-jobs";
  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ../jobs.nix ];
      # As the guest: units find the system's commands.
      systemd.settings.Manager.DefaultEnvironment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin HOME=/work";
      systemd.tmpfiles.rules = [ "d /work 0755 root root -" ];
      environment.systemPackages = [ pkgs.jq ];
      systemd.services.fake-max = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.nodejs}/bin/node ${host}";
      };
    };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_open_port(7777)
    machine.succeed("touch /run/wakes")

    def call(unit, command, options="", before=""):
        line = machine.succeed(
            f"{before}max-jobs run --unit max-job-{unit} {options} -- bash -lc '{command}'"
        )
        return json.loads(line)

    def wakes():
        return [json.loads(line) for line in machine.succeed("cat /run/wakes").splitlines()]

    def left(unit):
        return machine.succeed(
            f"ls -d /run/max/jobs/max-job-{unit} /work/.max/out/max-job-{unit}.* 2>/dev/null || true"
        ).split()

    with subtest("a call prints how it ended and what it wrote, and wakes nobody"):
        said = call("ok", "echo hi; (exit 3)", "--limit 30")
        assert (said["result"], said["code"], said["status"]) == ("exit-code", "exited", "3"), said
        assert said["out"] == {"bytes": 3, "head": "hi\n", "tail": "", "file": None}, said
        assert said["err"] is None and said["failed"] is None, said
        assert left("ok") == [], left("ok")

    with subtest("a call at its limit is stopped, and says so"):
        said = call("late", "echo start; sleep 60", "--limit 2")
        assert (said["result"], said["code"], said["status"]) == ("timeout", "killed", "TERM"), said
        assert said["out"]["head"] == "start\n", said

    with subtest("an output too long to show keeps its ends, and its file"):
        said = call("long", "seq 1 200", "--limit 30 --shown 100")
        file = "/work/.max/out/max-job-long.txt"
        assert said["out"]["file"] == file and said["out"]["bytes"] == 692, said
        assert said["out"]["head"].startswith("1\n2\n") and said["out"]["tail"].endswith("199\n200\n"), said
        assert left("long") == [file], left("long")
        assert machine.succeed(f"wc -l < {file}").strip() == "200"

    with subtest("a call has its input, its environment and its directory, and its stderr apart"):
        machine.succeed("mkdir -p /work/project")
        said = call(
            "input", "cat; echo $FOO >&2; pwd >&2",
            "--limit 30 --split --input --setenv FOO=bar --workdir /work/project",
            before="echo given | ",
        )
        assert said["out"]["head"] == "given\n", said
        assert said["err"]["head"] == "bar\n/work/project\n", said

    with subtest("a call that can't start says why"):
        said = call("nowhere", "true", "--limit 30 --workdir /no/such/directory")
        assert said["failed"] == "there is no directory /no/such/directory" and said["out"] is None, said
        machine.fail("max-jobs start --unit max-job-nowhere --limit 30 --workdir /no/such/directory -- true")
        assert left("nowhere") == [], left("nowhere")

    assert wakes() == [], wakes()

    with subtest("a background command returns at once, and its end wakes Max once"):
        machine.succeed(
            "timeout 2 max-jobs start --unit max-job-made --limit 60 --title '$ make' "
            "-- bash -lc 'echo building; sleep 3; echo built; (exit 1)'"
        )
        assert machine.succeed("max-jobs list --count").strip() == "1"
        listed = machine.succeed("max-jobs list")
        assert listed.startswith("max-job-made · ") and listed.strip().endswith("· job · $ make"), listed
        machine.wait_until_succeeds("test $(wc -l < /run/wakes) -eq 1", timeout=30)
        notice = wakes()[0]
        print(notice)
        assert notice.splitlines()[0] == "[max-job-made 完成] $ make", notice
        assert notice.splitlines()[1].startswith("exit status 1, ran for "), notice
        assert "building\nbuilt\n(the whole output: /work/.max/out/max-job-made.txt)" in notice, notice
        machine.wait_until_fails("test -e /run/max/jobs/max-job-made")
        assert machine.succeed("max-jobs list --count").strip() == "0"
        assert machine.succeed("cat /work/.max/out/max-job-made.txt") == "building\nbuilt\n"

    with subtest("a background command at its limit is told as stopped"):
        machine.succeed("max-jobs start --unit max-job-slow --limit 2 --title '$ sleep 60' -- bash -lc 'sleep 60'")
        machine.wait_until_succeeds("test $(wc -l < /run/wakes) -eq 2", timeout=30)
        notice = wakes()[1]
        assert notice.splitlines()[0] == "[max-job-slow 到点了，下面是做到一半的] $ sleep 60", notice
        assert "not done in 2 seconds; it was stopped\n(no output)" in notice, notice

    with subtest("a stopped one wakes nobody"):
        machine.succeed("max-jobs start --unit max-job-unwanted --limit 60 -- bash -lc 'sleep 60'")
        assert machine.succeed("max-jobs stop-all").split() == ["max-job-unwanted"]
        machine.wait_until_fails("test -e /run/max/jobs/max-job-unwanted")
        machine.succeed("sleep 3")
        assert len(wakes()) == 2, wakes()
        assert machine.succeed("max-jobs stop-all") == ""

    with subtest("while max is away the notice waits, and arrives once it is back"):
        machine.succeed("systemctl stop fake-max.service")
        machine.succeed("max-jobs start --unit max-job-meanwhile --limit 60 --title '$ true' -- bash -lc 'echo ran'")
        machine.wait_until_succeeds(
            "systemctl show -P NRestarts max-notify@max-job-meanwhile.service | grep -qx '[2-9]'", timeout=60
        )
        assert len(wakes()) == 2, wakes()
        waiting = machine.succeed("systemctl list-units --all --no-legend --plain 'max-notify@*'")
        assert "max-notify@max-job-meanwhile.service" in waiting, waiting
        machine.succeed("systemctl start fake-max.service")
        machine.wait_until_succeeds("test $(wc -l < /run/wakes) -eq 3", timeout=90)
        assert wakes()[2].startswith("[max-job-meanwhile 完成] $ true\nexit status 0, ran for "), wakes()[2]
        machine.wait_until_fails("test -e /run/max/jobs/max-job-meanwhile")

    with subtest("a call whose caller went away ends by itself, and nobody is told"):
        machine.fail("timeout 1 max-jobs run --unit max-job-orphan --limit 4 -- bash -lc 'echo x; sleep 60'")
        machine.succeed("systemctl is-active max-job-orphan.service")
        machine.wait_until_fails("systemctl is-active max-job-orphan.service", timeout=30)
        machine.wait_until_fails("test -e /run/max/jobs/max-job-orphan")
        assert left("orphan") == [], left("orphan")
        machine.succeed("sleep 2")
        assert len(wakes()) == 3, wakes()
  '';
}
