# What Max runs in a guest, as units (nix/jobs.nix, nix/max-jobs.sh): a
# call's line, a background command's notice, and what becomes of each
# when it is stopped, when max is away, and when its caller is; a call
# of maxx's made while max restarts, which is made again; and a
# background agent (nix/max-agent.sh), pi itself against a model that
# says what the test has it say. The machine has the guest's jobs without
# a VM's shares; a fake max at 127.0.0.1:7777 keeps what wakes it and
# answers for the agents' model.
{ pkgs, pi }:
let
  runner = import ../runner.nix { inherit pkgs; };
  host = pkgs.writeText "fake-max.js" ''
    const http = require("node:http");
    const fs = require("node:fs");
    const wake = { name: "wake", description: "Wakes Max.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } };
    // What the agents' model says, by the task and by how far it is: a
    // tool call, or its last words.
    const said = (task, n) => {
      if (task.includes("口味")) {
        return [{ tool: "max-agent ask 要哪种口味" }, { content: "等 Max 回答选哪家" }, { content: "订了火锅" }][n] ?? { content: "多说了" };
      }
      if (task.includes("很久")) return { content: "开始查", tool: "sleep 300" };
      return [{ tool: "sleep 3; echo 查过了" }, { content: "报告：做完了" }][n] ?? { content: "多说了" };
    };
    const text = message => (typeof message.content === "string" ? message.content : (message.content ?? []).map(part => part.text ?? "").join(""));
    const model = (body, res) => {
      const { messages } = JSON.parse(body);
      const users = messages.filter(message => message.role === "user").map(text);
      fs.appendFileSync("/run/llm-heard", JSON.stringify(users) + "\n");
      const n = messages.filter(message => message.role === "assistant").length;
      const { content, tool } = said(users[0] ?? "", n);
      const delta = { role: "assistant", content };
      if (tool) {
        const call = { name: "bash", arguments: JSON.stringify({ command: tool }) };
        delta.tool_calls = [{ index: 0, id: "call_" + n, type: "function", function: call }];
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write("data: " + JSON.stringify({ choices: [{ index: 0, delta }] }) + "\n\n");
      const finish = { index: 0, delta: {}, finish_reason: tool ? "tool_calls" : "stop" };
      res.write("data: " + JSON.stringify({ choices: [finish], usage: { prompt_tokens: 10, completion_tokens: 2 } }) + "\n\n");
      res.end("data: [DONE]\n\n");
    };
    http.createServer((req, res) => {
      let body = "";
      req.on("data", chunk => (body += chunk));
      req.on("end", () => {
        // As the guest's forwarder answers while max restarts.
        if (fs.existsSync("/run/away")) {
          res.writeHead(503, { "max-away": "1", "content-length": "0" });
          return res.end();
        }
        // The agents' model: what max says of it, and its calls.
        if (req.url === "/llm" && fs.existsSync("/run/no-model")) return res.writeHead(404).end();
        if (req.url === "/llm") {
          res.writeHead(200, { "content-type": "application/json" });
          return res.end(JSON.stringify({ api: "openai-completions", model: "m", window: 100000, max_output: null, effort: null }));
        }
        if (req.url === "/llm/chat/completions") return model(body, res);
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
      _module.args.pi = pi;
      # pi and what it runs take more than the default.
      virtualisation.memorySize = 2048;
      # As the guest: units find the system's commands.
      systemd.settings.Manager.DefaultEnvironment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin HOME=/work";
      systemd.tmpfiles.rules = [ "d /work 0755 root root -" ];
      environment.systemPackages = [
        pkgs.jq
        # maxx.
        runner
      ];
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
        assert said["err"] is None and said["failed"] is None and said["shown"] == [], said
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

    with subtest("a call has its input, its own directory and its working directory, and its stderr apart"):
        machine.succeed("mkdir -p /work/project")
        said = call(
            "input", "cat; echo $MAX_CALL >&2; pwd >&2",
            "--limit 30 --split --input --workdir /work/project",
            before="echo given | ",
        )
        assert said["out"]["head"] == "given\n", said
        assert said["err"]["head"] == "/run/max/jobs/max-job-input\n/work/project\n", said

    with subtest("what a call leaves for the model to see comes back on its line"):
        machine.succeed("printf x > /work/a.png; mkdir -p /work/.max/shown/max-job-old && touch -d '2 hours ago' /work/.max/shown/max-job-old")
        # A file, by maxx; one that isn't there, which maxx refuses; a
        # line a program wrote itself; and one that is no such line.
        said = call(
            "show",
            "maxx show a.png; maxx show nope.png; "
            "echo \"{\\\"kind\\\":\\\"video\\\",\\\"path\\\":\\\"/work/b.mp4\\\"}\" >> $MAX_CALL/shown; echo junk >> $MAX_CALL/shown",
            "--limit 30",
        )
        assert said["shown"] == [
            {"kind": "image", "path": "/work/a.png"},
            {"kind": "video", "path": "/work/b.mp4"},
        ], said
        assert "show: nope.png doesn't exist (not_found)" in said["out"]["head"], said
        assert left("show") == [], left("show")
        # What an earlier call left in /work for the host is cleared away.
        machine.fail("test -e /work/.max/shown/max-job-old")

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

    with subtest("a call made while max restarts is made again until it is back"):
        machine.succeed("touch /run/away")
        machine.succeed("(maxx wake --text 回来了吗 > /run/away.out 2>&1; echo $? > /run/away.status) > /dev/null 2>&1 &")
        machine.succeed("sleep 4")
        machine.fail("test -e /run/away.status")
        assert len(wakes()) == 3, wakes()
        machine.succeed("rm /run/away")
        machine.wait_until_succeeds("test -e /run/away.status", timeout=30)
        assert machine.succeed("cat /run/away.status").strip() == "0", machine.succeed("cat /run/away.out")
        assert wakes()[3] == "回来了吗", wakes()

    def woken(count):
        machine.wait_until_succeeds(f"test $(wc -l < /run/wakes) -ge {count}", timeout=180)
        return wakes()[count - 1]

    with subtest("an agent works on its task, is told more, and its report wakes Max"):
        said = machine.succeed("max-agent start --title 试试 --workdir proj <<< '查一下明天的天气'")
        assert said.startswith("max-agent-1 started in /work/proj, for at most 6 hours."), said
        listed = machine.succeed("max-jobs list")
        assert listed.startswith("max-agent-1 · ") and listed.strip().endswith("· agent · 试试"), listed
        machine.wait_until_succeeds("test -s /run/llm-heard", timeout=120)
        machine.succeed("max-agent steer max-agent-1 <<< '顺便看后天'")
        notice = woken(5)
        print(notice)
        assert notice == "[max-agent-1 完成] 试试\n报告：做完了\n（全文在 /work/.max/jobs/max-agent-1.md）", notice
        assert machine.succeed("cat /work/.max/jobs/max-agent-1.md") == "# max-agent-1 试试\n\n报告：做完了\n"
        heard = machine.succeed("tail -n 1 /run/llm-heard")
        assert "查一下明天的天气" in heard and "顺便看后天" in heard, heard
        machine.wait_until_fails("test -e /run/max/jobs/max-agent-1")
        # Its notes are its directory's, and it was told where.
        assert machine.succeed("ls /work/.max/projects /work/proj") == "/work/.max/projects:\n\n/work/proj:\n"

    with subtest("an agent that asks its Max waits for the answer"):
        machine.succeed("max-agent start <<< '订个餐，问问口味'")
        asked = woken(6)
        assert asked.startswith("[max-agent-2 问] 订个餐，问问口味\n要哪种口味\n（回答它用 max-agent steer max-agent-2"), asked
        machine.succeed("max-agent steer max-agent-2 <<< 火锅")
        notice = woken(7)
        assert notice.startswith("[max-agent-2 完成] 订个餐，问问口味\n订了火锅\n"), notice
        assert "火锅" in machine.succeed("tail -n 1 /run/llm-heard")

    with subtest("a stopped agent tells nobody, and is gone"):
        machine.succeed("max-agent start --title 久 <<< '这个要查很久'")
        machine.wait_until_succeeds("grep -q 很久 /run/llm-heard", timeout=120)
        machine.succeed("sleep 2; systemctl stop max-agent-3.service")
        machine.wait_until_fails("test -e /run/max/jobs/max-agent-3", timeout=60)
        refused = machine.fail("max-agent steer max-agent-3 <<< 算了 2>&1")
        assert "max-agent-3 isn't running" in refused, refused
        # What it had written is kept, though nobody is woken for it.
        assert "开始查" in machine.succeed("cat /work/.max/jobs/max-agent-3.md")
        machine.succeed("sleep 3")
        assert len(wakes()) == 7, wakes()

    with subtest("without a model for them there are no agents"):
        machine.succeed("touch /run/no-model")
        refused = machine.fail("max-agent start <<< '查一下' 2>&1")
        assert "no model is configured for background agents" in refused, refused
        machine.succeed("rm /run/no-model")
        assert "the task comes on standard input" in machine.fail("max-agent start < /dev/null 2>&1")
  '';
}
