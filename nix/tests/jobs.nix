# What Max runs in a guest, as units (nix/jobs.nix, nix/max-jobs.sh),
# asked for with maxx as max asks, its words and a JSON object, and as
# Max does, with options: a call's line, a background command's notice,
# and what becomes of each when it is stopped, when max is away, and when
# its caller is; a call of maxx's made while max restarts, which is made
# again; a background agent (nix/max-agent.sh), pi itself against a
# model that says what the test has it say; and a unit that
# /work/.max/systemd keeps (nix/max-units.sh). The machine has the
# guest's jobs without a VM's shares; a fake max at 127.0.0.1:7777 keeps
# what wakes it and answers for the agents' model.
{ pkgs, pi }:
let
  # The machine's own, by the same name: a program requires its tools.
  maxx = import ../maxx.nix {
    inherit pkgs pi;
    inherit (pkgs) systemd;
  };
  host = pkgs.writeText "fake-max.js" ''
    const http = require("node:http");
    const fs = require("node:fs");
    const wake = { name: "wake", description: "Wakes Max.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } };
    // What the agents' model says, by the task and by how far it is: a
    // tool call, or its last words.
    const said = (task, n) => {
      if (task.includes("口味")) {
        return [{ tool: "maxx agent ask 要哪种口味" }, { content: "等 Max 回答选哪家" }, { content: "订了火锅" }][n] ?? { content: "多说了" };
      }
      if (task.includes("很久")) return { content: "开始查", tool: "sleep 300" };
      return [{ tool: "sleep 3; echo 查过了" }, { content: "报告：做完了" }][n] ?? { content: "多说了" };
    };
    const text = message => (typeof message.content === "string" ? message.content : (message.content ?? []).map(part => part.text ?? "").join(""));
    // The models max says a call can name: the agents' own, and another.
    const own = { api: "openai-completions", model: "test/m", window: 100000, max_output: null };
    const wide = { api: "openai-completions", model: "test/team/wide", window: 200000, max_output: null };
    const model = (body, res) => {
      const { messages, model, reasoning_effort } = JSON.parse(body);
      const users = messages.filter(message => message.role === "user").map(text);
      fs.appendFileSync("/run/llm-heard", JSON.stringify(users) + "\n");
      // The model the call names, and how hard it asks it to think.
      fs.appendFileSync("/run/llm-asked", JSON.stringify([model, reasoning_effort ?? null]) + "\n");
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
        // The models: what max says of them, and their calls.
        if (req.url === "/llm" && fs.existsSync("/run/no-model")) return res.writeHead(404).end();
        if (req.url === "/llm") {
          res.writeHead(200, { "content-type": "application/json" });
          return res.end(JSON.stringify({ ...own, effort: null, models: [own, wide] }));
        }
        if (req.url === "/llm/chat/completions") return model(body, res);
        // The host's tools: the list, and a wake, which is kept.
        let answer = { ok: false, error: { code: "unknown_tool", message: "there is no such tool" } };
        if (req.method === "GET" && req.url === "/tools") answer = { tools: [wake] };
        if (req.method === "POST" && req.url === "/tools/wake") {
          fs.appendFileSync("/run/wakes", JSON.stringify(JSON.parse(body).text) + "\n");
          answer = { ok: true, value: { said: "woke Max" } };
        }
        // What max-units says of the units it found.
        if (req.url === "/units") answer = {};
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(answer));
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
        # A program of Max's own.
        pkgs.nodejs
      ];
      systemd.services.fake-max = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.nodejs}/bin/node ${host}";
      };
    };

  testScript = ''
    import json
    import shlex

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_open_port(7777)
    machine.succeed("touch /run/wakes")

    def maxx(words, **arguments):
        # As max asks: the words, and the arguments as a JSON object.
        return f"maxx {words} {shlex.quote(json.dumps(arguments, ensure_ascii=False))}"

    def call(unit, command, given="", **options):
        # Its caller gives the command its input, says nothing more, and
        # holds on for as long as it waits.
        if given:
            options["input"] = len(given.encode())
        line = machine.succeed(
            maxx("units run", unit=f"max-job-{unit}", command=command, **options)
            + f" < <(printf %s {shlex.quote(given)}; exec sleep 300 2> /dev/null)"
        )
        return json.loads(line)

    def start(unit, command, **options):
        return json.loads(machine.succeed(maxx("units start", unit=f"max-job-{unit}", command=command, **options)))

    def running():
        return json.loads(machine.succeed(maxx("units list")))["units"]

    def wakes():
        return [json.loads(line) for line in machine.succeed("cat /run/wakes").splitlines()]

    def left(unit):
        return machine.succeed(
            f"ls -d /run/max/jobs/max-job-{unit} /work/.max/out/max-job-{unit}.* 2>/dev/null || true"
        ).split()

    with subtest("a call prints how it ended and what it wrote, and wakes nobody"):
        said = call("ok", "echo hi; (exit 3)", limit=30)
        assert (said["result"], said["code"], said["status"]) == ("exit-code", "exited", "3"), said
        assert said["out"] == {"bytes": 3, "head": "hi\n", "tail": "", "file": None}, said
        assert said["err"] is None and said["failed"] is None and said["shown"] == [], said
        assert left("ok") == [], left("ok")

    with subtest("a call at its limit is stopped, and says so"):
        said = call("late", "echo start; sleep 60", limit=2)
        assert (said["result"], said["code"], said["status"]) == ("timeout", "killed", "TERM"), said
        assert said["out"]["head"] == "start\n", said

    with subtest("an output too long to show keeps its ends, and its file"):
        said = call("long", "seq 1 200", limit=30, shown=100)
        file = "/work/.max/out/max-job-long.txt"
        assert said["out"]["file"] == file and said["out"]["bytes"] == 692, said
        assert said["out"]["head"].startswith("1\n2\n") and said["out"]["tail"].endswith("199\n200\n"), said
        assert left("long") == [file], left("long")
        assert machine.succeed(f"wc -l < {file}").strip() == "200"

    with subtest("a call has its input, its own directory and its working directory, and its stderr apart"):
        machine.succeed("mkdir -p /work/project")
        said = call(
            "input", "cat; echo $MAX_CALL >&2; pwd >&2",
            given="given", limit=30, split=True, workdir="/work/project",
        )
        assert said["out"]["head"] == "given", said
        assert said["err"]["head"] == "/run/max/jobs/max-job-input\n/work/project\n", said
        # A directory that isn't absolute is under /work.
        said = call("under", "pwd", limit=30, workdir="project")
        assert said["out"]["head"] == "/work/project\n", said

    with subtest("what a call leaves for the model to see comes back on its line"):
        machine.succeed("printf x > /work/a.png; mkdir -p /work/.max/shown/max-job-old && touch -d '2 hours ago' /work/.max/shown/max-job-old")
        # A file, by maxx; one that isn't there, which maxx refuses; a
        # line a program wrote itself; and one that is no such line.
        said = call(
            "show",
            "maxx show a.png; maxx show nope.png; "
            "echo \"{\\\"kind\\\":\\\"video\\\",\\\"path\\\":\\\"/work/b.mp4\\\"}\" >> $MAX_CALL/shown; echo junk >> $MAX_CALL/shown",
            limit=30,
        )
        assert said["shown"] == [
            {"kind": "image", "path": "/work/a.png"},
            {"kind": "video", "path": "/work/b.mp4"},
        ], said
        assert "show: nope.png doesn't exist (not_found)" in said["out"]["head"], said
        assert left("show") == [], left("show")
        # What an earlier call left in /work for the host is cleared away.
        machine.fail("test -e /work/.max/shown/max-job-old")
        # More than max would show: the line keeps the first of them.
        said = call(
            "many",
            "for n in $(seq 40); do echo \"{\\\"kind\\\":\\\"image\\\",\\\"path\\\":\\\"/work/$n.png\\\"}\"; done >> $MAX_CALL/shown",
            limit=30,
        )
        assert len(said["shown"]) == 32 and said["shown"][31]["path"] == "/work/32.png", said

    with subtest("a call that can't start says why"):
        said = call("nowhere", "true", limit=30, workdir="/no/such/directory")
        assert said["failed"] == "there is no directory /no/such/directory" and said["out"] is None, said
        machine.fail(maxx("units start", unit="max-job-nowhere", limit=30, workdir="/no/such/directory", command="true"))
        assert left("nowhere") == [], left("nowhere")
        # What isn't what it takes is a wrong command line, and says what.
        for arguments, why in [
            ({"command": "true", "limit": "soon"}, "limit is a whole number"),
            ({"command": ["true"]}, "command is text"),
            ({"limit": 30}, "there is no command to run"),
            ({"command": "true", "limit": 90000}, "limit is a day at most, 86400 seconds"),
            ({"command": "true", "unit": "mine"}, "--unit is max-job-… or max-agent-…, not 'mine'"),
        ]:
            status, refused = machine.execute(maxx("units run", **arguments) + " 2>&1")
            assert status == 2 and refused.strip() == f"maxx units: {why}", (status, refused)

    with subtest("a call's command reaches bash as it was written"):
        # systemd would fill in ''${…} and $$ itself, in a quoted heredoc too.
        said = call(
            "written",
            "f=1; for g in a b; do echo \"[''${f}''${g}]\"; done; test $$ -gt 1 && echo pid; cat <<\\EOT\n[reply#''${id}] it's\nEOT",
            limit=30,
        )
        assert said["out"]["head"] == "[1a]\n[1b]\npid\n[reply#''${id}] it's\n", said

    with subtest("a call that removes its own directory still says how it ended"):
        machine.succeed("mkdir -p /work/tmp/gone")
        said = call("gone", "echo done; cd / && rm -rf /work/tmp/gone", limit=30, workdir="/work/tmp/gone")
        assert (said["result"], said["status"], said["failed"]) == ("success", "0", None), said
        assert said["out"]["head"] == "done\n", said
        assert left("gone") == [], left("gone")

    with subtest("a call names itself and has two minutes when nothing says otherwise, as one of Max's own does"):
        # With options, which Node reads, and holds the call's input.
        said = json.loads(machine.succeed("maxx units run --command 'echo $MAX_CALL; systemctl show -P RuntimeMaxUSec $(basename $MAX_CALL)'"))
        name, limit = said["out"]["head"].split()[0], said["out"]["head"].split("\n")[1]
        assert name.startswith("/run/max/jobs/max-job-") and len(name) == len("/run/max/jobs/max-job-") + 16, said
        assert limit == "2min" and said["result"] == "success", said
        # Nobody holds the input of a command in a unit: it isn't one who
        # could go.
        said = json.loads(machine.succeed(maxx("units run", command="echo here") + " < /dev/null"))
        assert (said["result"], said["out"]["head"]) == ("success", "here\n"), said

    with subtest("the caches are dropped once nothing has run for ten minutes, and not before"):
        def dropped():
            return int(machine.succeed("grep -w drop_pagecache /proc/vmstat | cut -d' ' -f2"))

        def trimmed(ago=None):
            # As if the last of what ran were that long ago.
            if ago:
                machine.succeed(f"find /run/max/jobs -maxdepth 1 -exec touch -d '{ago} minutes ago' {{}} +")
            machine.succeed("systemctl start max-trim.service")
            return dropped() - before

        before = dropped()
        # A call has just ended: the next one may read what it wrote.
        assert trimmed() == 0
        # Long since, but a background command runs.
        start("busy", "sleep 60", limit=60)
        assert trimmed(ago=11) == 0
        machine.succeed("systemctl stop max-job-busy")
        machine.wait_until_fails("test -e /run/max/jobs/max-job-busy")
        # It has just ended, and nine minutes on isn't ten.
        assert trimmed() == 0
        assert trimmed(ago=9) == 0
        assert trimmed(ago=11) == 1
        machine.fail("maxx units idle soon")

    assert wakes() == [], wakes()

    with subtest("a background command returns at once, and its end wakes Max once"):
        started = json.loads(machine.succeed(
            "timeout 2 "
            + maxx("units start", unit="max-job-made", limit=60, title="$ make", command="echo building; sleep 3; echo built; (exit 1)")
        ))
        assert (started["unit"], started["limit"]) == ("max-job-made", 60), started
        assert started["said"].startswith(
            "It runs in the background as max-job-made, for at most 1 minutes. "
            "When it ends, its exit status and output come back to you as [max-job-made 完成]: don't sleep waiting"
        ), started
        assert started["said"].endswith("stop it with systemctl stop max-job-made."), started
        listed = running()
        assert len(listed) == 1 and listed[0]["seconds"] >= 0, listed
        assert (listed[0]["name"], listed[0]["kind"], listed[0]["title"]) == ("max-job-made", "job", "$ make"), listed
        machine.wait_until_succeeds("test $(wc -l < /run/wakes) -eq 1", timeout=30)
        notice = wakes()[0]
        print(notice)
        assert notice.splitlines()[0] == "[max-job-made 完成] $ make", notice
        assert notice.splitlines()[1].startswith("exit status 1, ran for "), notice
        assert "building\nbuilt\n(the whole output: /work/.max/out/max-job-made.txt)" in notice, notice
        machine.wait_until_fails("test -e /run/max/jobs/max-job-made")
        assert running() == [], running()
        assert machine.succeed("cat /work/.max/out/max-job-made.txt") == "building\nbuilt\n"

    with subtest("a background command at its limit is told as stopped"):
        start("slow", "sleep 60", limit=2, title="$ sleep 60")
        machine.wait_until_succeeds("test $(wc -l < /run/wakes) -eq 2", timeout=30)
        notice = wakes()[1]
        assert notice.splitlines()[0] == "[max-job-slow 到点了，下面是做到一半的] $ sleep 60", notice
        assert "not done in 2 seconds; it was stopped\n(no output)" in notice, notice

    with subtest("a stopped one wakes nobody, however it takes the signal"):
        start("unwanted", "sleep 60", limit=60)
        # A server's way: it ends by itself when asked to, with a status.
        start("server", "trap \"exit 3\" TERM; echo up; sleep 60 & wait", limit=60)
        machine.wait_until_succeeds("grep -q up /work/.max/out/max-job-server.txt")
        stopped = json.loads(machine.succeed(maxx("units stop-all")))
        assert sorted(stopped["stopped"]) == ["max-job-server", "max-job-unwanted"], stopped
        machine.wait_until_fails("test -e /run/max/jobs/max-job-unwanted")
        machine.wait_until_fails("test -e /run/max/jobs/max-job-server")
        machine.succeed("sleep 3")
        assert len(wakes()) == 2, wakes()
        assert json.loads(machine.succeed("maxx units stop-all")) == {"stopped": []}

    with subtest("while max is away the notice waits, and arrives once it is back"):
        machine.succeed("systemctl stop fake-max.service")
        start("meanwhile", "echo ran", limit=60, title="$ true")
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

    with subtest("a call whose caller went away is stopped, and nobody is told"):
        # The caller holds on for two seconds of the call's sixty.
        machine.succeed(
            "timeout 30 "
            + maxx("units run", unit="max-job-left", limit=60, command="echo x; sleep 60")
            + " < <(sleep 2) > /run/left.out"
        )
        machine.fail("systemctl is-active max-job-left.service")
        assert machine.succeed("cat /run/left.out") == ""
        assert left("left") == [], left("left")
        # Gone before the unit was there to stop.
        machine.succeed(
            "timeout 30 " + maxx("units run", unit="max-job-early", limit=60, command="sleep 60") + " < <(true)"
        )
        machine.fail("systemctl is-active max-job-early.service")
        assert left("early") == [], left("early")

    with subtest("a call whose own command was killed ends at its limit, and nobody is told"):
        machine.fail(
            "timeout 1 "
            + maxx("units run", unit="max-job-orphan", limit=4, command="echo x; sleep 60")
            + " < <(exec sleep 300 2> /dev/null)"
        )
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
        # As Max starts one: with options, and the task on standard input.
        said = json.loads(machine.succeed("maxx agent start --title 试试 --workdir proj --task - <<< '查一下明天的天气'"))
        assert said["name"] == "max-agent-1", said
        assert said["said"].startswith("max-agent-1 started in /work/proj on test/m, for at most 6 hours."), said
        assert "maxx agent steer max-agent-1" in said["said"], said
        listed = running()
        assert [(unit["name"], unit["kind"], unit["title"]) for unit in listed] == [("max-agent-1", "agent", "试试")], listed
        machine.wait_until_succeeds("test -s /run/llm-heard", timeout=120)
        told = json.loads(machine.succeed("maxx agent steer max-agent-1 --text - <<< '顺便看后天'"))
        assert told == {"said": "max-agent-1 will read it at the end of the step it is in."}, told
        notice = woken(5)
        print(notice)
        assert notice == "[max-agent-1 完成] 试试\n报告：做完了\n（全文在 /work/.max/jobs/max-agent-1.md）", notice
        assert machine.succeed("cat /work/.max/jobs/max-agent-1.md") == "# max-agent-1 试试\n\n报告：做完了\n"
        heard = machine.succeed("tail -n 1 /run/llm-heard")
        assert "查一下明天的天气" in heard and "顺便看后天" in heard, heard
        # On the agents' own model, by max's name for it.
        assert machine.succeed("sort -u /run/llm-asked") == '["test/m",null]\n'
        machine.wait_until_fails("test -e /run/max/jobs/max-agent-1")
        # Its notes are its directory's, and it was told where.
        assert machine.succeed("ls /work/.max/projects /work/proj") == "/work/.max/projects:\n\n/work/proj:\n"

    with subtest("an agent that asks its Max waits for the answer"):
        machine.succeed(maxx("agent start", task="订个餐，问问口味"))
        asked = woken(6)
        assert asked.startswith("[max-agent-2 问] 订个餐，问问口味\n要哪种口味\n（回答它用 maxx agent steer max-agent-2 '回答'"), asked
        # By position, as that says.
        machine.succeed("maxx agent steer max-agent-2 火锅")
        notice = woken(7)
        assert notice.startswith("[max-agent-2 完成] 订个餐，问问口味\n订了火锅\n"), notice
        assert "火锅" in machine.succeed("tail -n 1 /run/llm-heard")
        # Nobody but an agent asks.
        refused = machine.fail("maxx agent ask 在吗 2>&1")
        assert "ask is for an agent to ask its Max" in refused, refused

    with subtest("a stopped agent tells nobody, and is gone"):
        machine.succeed("maxx agent start --title 久 --task 这个要查很久")
        machine.wait_until_succeeds("grep -q 很久 /run/llm-heard", timeout=120)
        machine.succeed("sleep 2; systemctl stop max-agent-3.service")
        machine.wait_until_fails("test -e /run/max/jobs/max-agent-3", timeout=60)
        refused = machine.fail("maxx agent steer max-agent-3 算了 2>&1")
        assert refused.strip() == "agent steer: max-agent-3 isn't running: it ended, was stopped, or never was (failed)", refused
        # What it had written is kept, though nobody is woken for it.
        assert "开始查" in machine.succeed("cat /work/.max/jobs/max-agent-3.md")
        machine.succeed("sleep 3")
        assert len(wakes()) == 7, wakes()

    with subtest("an agent runs on the model Max names, and thinks as hard as told"):
        listed = json.loads(machine.succeed("maxx agent models"))
        assert listed == {"models": [
            {"model": "test/m", "window": 100000, "default": True},
            {"model": "test/team/wide", "window": 200000, "default": False},
        ]}, listed
        said = json.loads(machine.succeed("maxx agent start --model test/team/wide --effort xhigh --title 换个模型 --task - <<< '查一下后天的天气'"))
        assert said["said"].startswith("max-agent-4 started in /work on test/team/wide, for at most 6 hours."), said
        notice = woken(8)
        assert notice.startswith("[max-agent-4 完成] 换个模型\n报告：做完了\n"), notice
        assert machine.succeed("tail -n 1 /run/llm-asked") == '["test/team/wide","xhigh"]\n'
        # One max doesn't have starts nothing, and takes no number.
        refused = machine.fail("maxx agent start --model test/nope --task 查一下 2>&1")
        assert "there is no model test/nope: maxx agent models lists them" in refused, refused
        refused = machine.fail("maxx agent start --effort hard --task 查一下 2>&1")
        assert "effort is one of off, minimal, low, medium, high, xhigh and max, not hard" in refused, refused
        assert machine.succeed("cat /work/.max/jobs/.count").strip() == "4"

    with subtest("without a model for them there are no agents"):
        machine.succeed("touch /run/no-model")
        refused = machine.fail("maxx agent start --task 查一下 2>&1")
        assert "no model is configured for background agents" in refused, refused
        machine.succeed("rm /run/no-model")
        assert "there is no task" in machine.fail("maxx agent start < /dev/null 2>&1")
        # What isn't text is a wrong command line.
        status, refused = machine.execute(maxx("agent start", task=5) + " 2>&1")
        assert status == 2 and refused.strip() == "task is text", (status, refused)

    with subtest("a background command that removes its own directory is still told of"):
        machine.succeed("mkdir -p /work/tmp/gone")
        start("gone", "echo going; cd / && rm -rf /work/tmp/gone", limit=60, title="$ rm", workdir="/work/tmp/gone")
        notice = woken(9)
        assert notice.startswith("[max-job-gone 完成] $ rm\nexit status 0, ran for "), notice
        machine.wait_until_fails("test -e /run/max/jobs/max-job-gone")

    with subtest("a background command that ends itself with SIGTERM is told of, as nobody asked"):
        start("self", "echo bye; kill -TERM $$", limit=60, title="$ kill")
        notice = woken(10)
        assert notice.startswith("[max-job-self 完成] $ kill\nended by SIGTERM, after "), notice

    with subtest("a background command of Max's own starting is named and titled here"):
        started = json.loads(machine.succeed("maxx units start 'sleep 600\necho second line'"))
        assert started["unit"].startswith("max-job-") and started["limit"] == 21600, started
        assert "for at most 6 hours 0 minutes" in started["said"], started
        listed = running()
        assert [(unit["name"], unit["kind"], unit["title"]) for unit in listed] == [(started["unit"], "job", "$ sleep 600")], listed

    with subtest("what /work/.max/systemd keeps is listed with what runs, and isn't stopped with it"):
        machine.succeed("mkdir -p /work/.max/systemd")
        machine.succeed("printf '[Service]\nExecStart=/run/current-system/sw/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' > /work/.max/systemd/keep.service")
        machine.succeed("printf '[Service]\nExecStart=/run/current-system/sw/bin/false\n[Install]\nWantedBy=multi-user.target\n' > /work/.max/systemd/broken.service")
        machine.succeed("ln -s keep.service /work/.max/systemd/link.service")
        applied = json.loads(machine.succeed("maxx units apply"))
        states = {unit["name"]: unit["state"] for unit in applied["units"]}
        assert states == {"broken.service": "failed", "keep.service": "active"}, applied
        assert all(("log" in unit) == (unit["state"] == "failed") for unit in applied["units"]), applied
        assert applied["skipped"] == [{"name": "link.service", "why": "a link, not installed; put the file itself here"}], applied
        assert applied["removed"] == [], applied
        kinds = sorted((unit["kind"], unit["name"], unit.get("state")) for unit in running())
        assert kinds == [
            ("job", started["unit"], None),
            ("unit", "broken.service", "failed"),
            ("unit", "keep.service", "active"),
        ], kinds
        # A program has the same tools, by their names: the list, and all
        # that was started stopped.
        program = "const { tools } = require('${maxx}/lib/max-runner/tools.js'); (async () => { const { units } = await tools.units_list(); console.log(JSON.stringify([units.length, await tools.units_stop_all()])); })()"
        assert json.loads(machine.succeed(f"node -e {shlex.quote(program)}")) == [3, {"stopped": [started["unit"]]}]
        machine.succeed("systemctl is-active keep.service")
        # Gone from the directory, it is stopped and removed.
        machine.succeed("rm /work/.max/systemd/keep.service /work/.max/systemd/link.service")
        applied = json.loads(machine.succeed(maxx("units apply")))
        assert applied["removed"] == ["keep.service"] and applied["skipped"] == [], applied
        machine.fail("systemctl is-active keep.service")
        machine.succeed("sleep 2")
        assert len(wakes()) == 10, wakes()
  '';
}
