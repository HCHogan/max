# What Max runs in a guest, as units (nix/jobs.nix, nix/max-jobs.sh),
# asked for as max asks, `maxx jobs` and a JSON object: a call's line, a
# background command's notice, and what becomes of each when it is
# stopped, when max is away, and when its caller is; what max asks the
# guest's systemd of them; a call of maxx's made while max restarts,
# which waits; a background agent, the guest's fx (nix/fx.sh) in a
# background command against a model that says what the test has it say,
# and the same agent going on; and a unit that /work/.max/systemd keeps
# (nix/max-units.sh). The machine has the guest's jobs without a VM's
# shares; a fake max at 127.0.0.1:7777 keeps what wakes it and answers
# for the agents' model.
{ pkgs, fx }:
let
  # The machine's own, by the same name: a program requires its tools.
  maxx = import ../maxx.nix {
    inherit pkgs;
    inherit (pkgs) systemd;
  };
  host = pkgs.writeText "fake-max.js" ''
    const http = require("node:http");
    const fs = require("node:fs");
    const wake = { name: "wake", description: "Wakes Max.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } };
    // What the agents' model says, by how far it is: a tool call, or its
    // last words.
    const said = n => [{ tool: "sleep 3; echo 查过了" }, { content: "报告：做完了" }][n] ?? { content: "多说了" };
    const text = message => (typeof message.content === "string" ? message.content : (message.content ?? []).map(part => part.text ?? "").join(""));
    // The models max says a call can name: the agents' own, and another.
    const own = { api: "openai-chat-completions", model: "test/m", window: 100000, max_output: null };
    const wide = { api: "openai-chat-completions", model: "test/team/wide", window: 200000, max_output: null };
    const model = (body, res) => {
      const { messages, model, reasoning_effort } = JSON.parse(body);
      const users = messages.filter(message => message.role === "user").map(text);
      fs.appendFileSync("/run/llm-heard", JSON.stringify(users) + "\n");
      // The model the call names, and how hard it asks it to think.
      fs.appendFileSync("/run/llm-asked", JSON.stringify([model, reasoning_effort ?? null]) + "\n");
      const n = messages.filter(message => message.role === "assistant").length;
      const { content, tool } = said(n);
      const delta = { role: "assistant", content };
      if (tool) {
        const call = { name: "shell", arguments: JSON.stringify({ action: "run", command: tool }) };
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
      req.on("end", async () => {
        // While max restarts, what is asked waits at its socket on the
        // host, and the max that comes answers.
        while (fs.existsSync("/run/away")) await new Promise(resolve => setTimeout(resolve, 200));
        // The models: what max says of them, and their calls.
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
      # fx and what it runs take more than the default.
      virtualisation.memorySize = 2048;
      # As the guest: units find the system's commands.
      systemd.settings.Manager.DefaultEnvironment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin HOME=/work";
      systemd.tmpfiles.rules = [ "d /work 0755 root root -" ];
      environment.systemPackages = [
        pkgs.jq
        # A program of Max's own.
        pkgs.nodejs
        # The background agents' harness, as the guest has it.
        (import ../fx.nix { inherit pkgs fx; })
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

    def call(command, given="", **options):
        # Its caller gives the command its input, says nothing more, and
        # holds on for as long as it waits.
        options = {"limit": 30, "shown": 16384} | options
        if given:
            options["input"] = len(given.encode())
        line = machine.succeed(
            maxx("jobs run", command=command, **options)
            + f" < <(printf %s {shlex.quote(given)}; exec sleep 300 2> /dev/null)"
        )
        return json.loads(line)

    def start(command, **options):
        # A background command: its unit's name.
        options = {"limit": 60} | options
        return json.loads(machine.succeed(maxx("jobs start", command=command, **options)))["unit"]

    def running():
        # As systemd has them, which is all that is kept of them.
        listed = machine.succeed(
            "systemctl list-units --no-legend --plain --state=active,activating,deactivating"
            " 'max-call-*.service' 'max-job-*.service'"
        )
        return [line.split()[0].removesuffix(".service") for line in listed.splitlines()]

    def wakes():
        return [json.loads(line) for line in machine.succeed("cat /run/wakes").splitlines()]

    def left():
        # What calls leave behind them.
        return machine.succeed("ls -d /run/max/jobs/max-call-* /work/.max/out/max-call-* 2>/dev/null || true").split()

    with subtest("a call prints how it ended and what it wrote, and wakes nobody"):
        said = call("echo hi; (exit 3)")
        assert (said["result"], said["code"], said["status"]) == ("exit-code", "exited", "3"), said
        assert said["out"] == {"bytes": 3, "head": "hi\n", "tail": "", "file": None}, said
        assert said["err"] is None and said["failed"] is None and said["shown"] == [], said
        assert left() == [], left()

    with subtest("a call at its limit is stopped, and says so"):
        said = call("echo start; sleep 60", limit=2)
        assert (said["result"], said["code"], said["status"]) == ("timeout", "killed", "TERM"), said
        assert said["out"]["head"] == "start\n", said

    with subtest("an output too long to show keeps its ends, and its file"):
        said = call("seq 1 200", shown=100)
        file = said["out"]["file"]
        assert file.startswith("/work/.max/out/max-call-") and file.endswith(".txt"), said
        assert said["out"]["bytes"] == 692, said
        assert said["out"]["head"].startswith("1\n2\n") and said["out"]["tail"].endswith("199\n200\n"), said
        assert left() == [file], left()
        assert machine.succeed(f"wc -l < {file}").strip() == "200"
        machine.succeed(f"rm {file}")

    with subtest("a call has its input, a directory and a name of its own, its working directory, and its stderr apart"):
        machine.succeed("mkdir -p /work/project")
        said = call("cat; echo $MAX_CALL >&2; pwd >&2", given="given", split=True, workdir="/work/project")
        assert said["out"]["head"] == "given", said
        own, where = said["err"]["head"].split()
        assert own.startswith("/run/max/jobs/max-call-") and len(own) == len("/run/max/jobs/max-call-") + 16, said
        assert where == "/work/project", said
        # A directory that isn't absolute is under /work.
        said = call("pwd", workdir="project")
        assert said["out"]["head"] == "/work/project\n", said
        # Nobody holds the input of a command given none: it isn't one
        # who could go, and the call runs to its end.
        said = json.loads(machine.succeed(maxx("jobs run", command="echo here", limit=30, shown=100) + " < /dev/null"))
        assert (said["result"], said["out"]["head"]) == ("success", "here\n"), said

    with subtest("what a call leaves for the model to see comes back on its line"):
        machine.succeed("printf x > /work/a.png; mkdir -p /work/.max/shown/max-call-old && touch -d '2 hours ago' /work/.max/shown/max-call-old")
        # A file, by maxx; one that isn't there, which maxx refuses; a
        # line a program wrote itself; and one that is no such line.
        said = call(
            "maxx show a.png; maxx show nope.png; "
            "echo \"{\\\"kind\\\":\\\"video\\\",\\\"path\\\":\\\"/work/b.mp4\\\"}\" >> $MAX_CALL/shown; echo junk >> $MAX_CALL/shown",
        )
        assert said["shown"] == [
            {"kind": "image", "path": "/work/a.png"},
            {"kind": "video", "path": "/work/b.mp4"},
        ], said
        assert "show: nope.png doesn't exist (not_found)" in said["out"]["head"], said
        assert left() == [], left()
        # What an earlier call left in /work for the host is cleared away.
        machine.fail("test -e /work/.max/shown/max-call-old")
        # More than max would show: the line keeps the first of them.
        said = call(
            "for n in $(seq 40); do echo \"{\\\"kind\\\":\\\"image\\\",\\\"path\\\":\\\"/work/$n.png\\\"}\"; done >> $MAX_CALL/shown",
        )
        assert len(said["shown"]) == 32 and said["shown"][31]["path"] == "/work/32.png", said

    with subtest("a call that can't start says why"):
        said = call("true", workdir="/no/such/directory")
        assert said["failed"] == "there is no directory /no/such/directory" and said["out"] is None, said
        machine.fail(maxx("jobs start", limit=30, workdir="/no/such/directory", command="true"))
        assert left() == [], left()
        # What isn't what it takes is a wrong command line, and says what.
        for arguments, why in [
            ({"command": "true", "limit": "soon", "shown": 100}, "limit is a whole number"),
            ({"command": ["true"], "limit": 30, "shown": 100}, "command is text"),
            ({"limit": 30, "shown": 100}, "there is no command to run"),
            ({"command": "true", "shown": 100}, "there is no limit, the seconds it may run"),
        ]:
            status, refused = machine.execute(maxx("jobs run", **arguments) + " 2>&1")
            assert status == 2 and refused.strip() == f"maxx jobs: {why}", (status, refused)
        status, refused = machine.execute("maxx jobs start '{\"command\": ' 2>&1")
        assert status == 2 and refused.startswith("maxx jobs: "), (status, refused)
        assert running() == [], running()

    with subtest("a call's command reaches bash as it was written"):
        # systemd would fill in ''${…} and $$ itself, in a quoted heredoc too.
        said = call(
            "f=1; for g in a b; do echo \"[''${f}''${g}]\"; done; test $$ -gt 1 && echo pid; cat <<\\EOT\n[reply#''${id}] it's\nEOT",
        )
        assert said["out"]["head"] == "[1a]\n[1b]\npid\n[reply#''${id}] it's\n", said

    with subtest("a call that removes its own directory still says how it ended"):
        machine.succeed("mkdir -p /work/tmp/gone")
        said = call("echo done; cd / && rm -rf /work/tmp/gone", workdir="/work/tmp/gone")
        assert (said["result"], said["status"], said["failed"]) == ("success", "0", None), said
        assert said["out"]["head"] == "done\n", said
        assert left() == [], left()

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
        busy = start("sleep 60")
        assert trimmed(ago=11) == 0
        machine.succeed(f"systemctl stop {busy}")
        assert running() == [], running()
        # It has just ended, and nine minutes on isn't ten.
        assert trimmed() == 0
        assert trimmed(ago=9) == 0
        assert trimmed(ago=11) == 1
        machine.fail("maxx jobs idle soon")

    assert wakes() == [], wakes()

    with subtest("a background command returns at once, and its end wakes Max once"):
        started = json.loads(machine.succeed(
            "timeout 2 " + maxx("jobs start", limit=60, title="$ make", command="echo building; sleep 3; echo built; (exit 1)")
        ))
        made = started["unit"]
        assert made.startswith("max-job-") and len(made) == len("max-job-") + 16, started
        assert started == {"unit": made, "out": f"/work/.max/out/{made}.txt"}, started
        # What it is is systemd's to keep: its name, and its title.
        assert running() == [made], running()
        assert machine.succeed(f"systemctl show -P Description {made}").strip() == "$ make"
        machine.wait_until_succeeds("test $(wc -l < /run/wakes) -eq 1", timeout=30)
        notice = wakes()[0]
        print(notice)
        assert notice.splitlines()[0] == f"[{made} 完成] $ make", notice
        assert notice.splitlines()[1].startswith("exit status 1, ran for "), notice
        assert f"building\nbuilt\n(the whole output: /work/.max/out/{made}.txt)" in notice, notice
        machine.wait_until_fails(f"test -e /run/max/jobs/{made}.json")
        assert running() == [], running()
        assert machine.succeed(f"cat /work/.max/out/{made}.txt") == "building\nbuilt\n"

    with subtest("a command without a title has its first line for one, 200 characters of it"):
        line = "sleep 60 # " + "参" * 300
        long = start(f"\n  {line}\necho second line")
        assert machine.succeed(f"systemctl show -P Description {long}").strip() == "$ " + line[:200] + "…"
        machine.succeed(f"systemctl stop {long}")

    with subtest("a background command at its limit is told as stopped"):
        slow = start("sleep 60", limit=2, title="$ sleep 60")
        machine.wait_until_succeeds("test $(wc -l < /run/wakes) -eq 2", timeout=30)
        notice = wakes()[1]
        assert notice.splitlines()[0] == f"[{slow} 到点了，下面是做到一半的] $ sleep 60", notice
        assert "not done in 2s; it was stopped\n(no output)" in notice, notice

    with subtest("max asks the guest's systemd whether any runs, and has it stop them all, which wakes nobody"):
        # As max does (vm.rs): by how systemctl ends, with nothing read.
        busy = "systemctl is-active --quiet 'max-job-*.service'"
        machine.fail(busy)
        start("sleep 60")
        # A server's way: it ends by itself when asked to, with a status.
        server = start("trap \"exit 3\" TERM; echo up; sleep 60 & wait")
        machine.wait_until_succeeds(f"grep -q up /work/.max/out/{server}.txt")
        machine.succeed(busy)
        assert len(running()) == 2, running()
        machine.succeed("systemctl stop 'max-job-*.service'")
        machine.fail(busy)
        assert running() == [], running()
        # With none to stop, it is no failure.
        machine.succeed("systemctl stop 'max-job-*.service'")
        machine.succeed("sleep 3")
        assert len(wakes()) == 2, wakes()
        assert machine.succeed("ls /run/max/jobs").split() == [], machine.succeed("ls /run/max/jobs")

    with subtest("while max is away the notice waits, and arrives once it is back"):
        machine.succeed("systemctl stop fake-max.service")
        meanwhile = start("echo ran", title="$ true")
        machine.wait_until_succeeds(
            f"systemctl show -P NRestarts max-notify@{meanwhile}.service | grep -qx '[2-9]'", timeout=60
        )
        assert len(wakes()) == 2, wakes()
        waiting = machine.succeed("systemctl list-units --all --no-legend --plain 'max-notify@*'")
        assert f"max-notify@{meanwhile}.service" in waiting, waiting
        machine.succeed("systemctl start fake-max.service")
        machine.wait_until_succeeds("test $(wc -l < /run/wakes) -eq 3", timeout=90)
        assert wakes()[2].startswith(f"[{meanwhile} 完成] $ true\nexit status 0, ran for "), wakes()[2]
        machine.wait_until_fails(f"test -e /run/max/jobs/{meanwhile}.json")

    with subtest("a call whose caller went away is stopped, and nobody is told"):
        # The caller holds on for two seconds of the call's sixty.
        machine.succeed(
            "timeout 30 "
            + maxx("jobs run", limit=60, shown=100, command="echo x; sleep 60")
            + " < <(sleep 2) > /run/left.out"
        )
        assert running() == [], running()
        assert machine.succeed("cat /run/left.out") == ""
        assert left() == [], left()
        # Gone before the unit was there to stop.
        machine.succeed(
            "timeout 30 " + maxx("jobs run", limit=60, shown=100, command="sleep 60") + " < <(true)"
        )
        assert running() == [], running()
        assert left() == [], left()

    with subtest("a call whose own command was killed ends at its limit, and nobody is told"):
        machine.fail(
            "timeout 1 "
            + maxx("jobs run", limit=4, shown=100, command="echo x; sleep 60")
            + " < <(exec sleep 300 2> /dev/null)"
        )
        orphans = running()
        assert len(orphans) == 1 and orphans[0].startswith("max-call-"), orphans
        machine.wait_until_fails(f"systemctl is-active {orphans[0]}.service", timeout=30)
        machine.wait_until_fails(f"test -e /run/max/jobs/{orphans[0]}")
        assert left() == [], left()
        machine.succeed("sleep 2")
        assert len(wakes()) == 3, wakes()

    with subtest("a call made while max restarts waits until it is back"):
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

    with subtest("an agent is fx in a background command, whose last words wake Max and whose session goes on"):
        # As Max runs one: in its directory, by a name, the task on
        # standard input. The notice names it by the command's first line.
        machine.succeed("mkdir -p /work/proj")
        first = "cd /work/proj && fx ask --session weather <<'EOF'"
        agent = start(f"{first}\n查一下明天的天气\nEOF", limit=600)
        notice = woken(5)
        assert notice.startswith(f"[{agent} 完成] $ {first}\nexit status 0, ran for "), notice
        assert "报告：做完了" in notice, notice
        # On the agents' own model, by max's name for it, asked for no
        # effort: max says it has none.
        assert machine.succeed("sort -u /run/llm-asked") == '["test/m",null]\n'
        # The same name in the same directory goes on with all of it, on
        # the model and effort named.
        again = start("cd /work/proj && fx ask --session weather --model test/team/wide --effort xhigh 顺便看后天", limit=600, title="$ again")
        notice = woken(6)
        assert notice.startswith(f"[{again} 完成] $ again\nexit status 0, "), notice
        heard = json.loads(machine.succeed("tail -n 1 /run/llm-heard"))
        assert "查一下明天的天气" in heard[0] and "顺便看后天" in heard[-1], heard
        assert machine.succeed("tail -n 1 /run/llm-asked") == '["test/team/wide","xhigh"]\n'
        # In another directory it is refused, before any call.
        calls = machine.succeed("wc -l < /run/llm-heard")
        said = call("fx ask --session weather 接着", limit=60)
        assert said["status"] == "2" and "the session weather is in /work/proj, not /work" in said["out"]["head"], said
        assert machine.succeed("wc -l < /run/llm-heard") == calls

    with subtest("a background command that removes its own directory is still told of"):
        machine.succeed("mkdir -p /work/tmp/gone")
        gone = start("echo going; cd / && rm -rf /work/tmp/gone", title="$ rm", workdir="/work/tmp/gone")
        notice = woken(7)
        assert notice.startswith(f"[{gone} 完成] $ rm\nexit status 0, ran for "), notice

    with subtest("a background command that ends itself with SIGTERM is told of, as nobody asked"):
        own = start("echo bye; kill -TERM $$", title="$ kill")
        notice = woken(8)
        assert notice.startswith(f"[{own} 完成] $ kill\nended by SIGTERM, after "), notice

    with subtest("what /work/.max/systemd keeps is installed, and a program has the tool by its name"):
        machine.succeed("mkdir -p /work/.max/systemd")
        machine.succeed("printf '[Service]\nExecStart=/run/current-system/sw/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' > /work/.max/systemd/keep.service")
        machine.succeed("printf '[Service]\nExecStart=/run/current-system/sw/bin/false\n[Install]\nWantedBy=multi-user.target\n' > /work/.max/systemd/broken.service")
        machine.succeed("ln -s keep.service /work/.max/systemd/link.service")
        # As Max asks, by its words.
        applied = json.loads(machine.succeed("maxx units apply"))
        states = {unit["name"]: unit["state"] for unit in applied["units"]}
        assert states == {"broken.service": "failed", "keep.service": "active"}, applied
        assert all(("log" in unit) == (unit["state"] == "failed") for unit in applied["units"]), applied
        assert applied["skipped"] == [{"name": "link.service", "why": "a link, not installed; put the file itself here"}], applied
        assert applied["removed"] == [], applied
        # It takes no arguments, and says so of one.
        status, refused = machine.execute(maxx("units apply", dry=True) + " 2>&1")
        assert (status, refused.strip()) == (2, "maxx units apply: it takes no arguments"), (status, refused)
        # A unit Max keeps is none of what it started: what stops those
        # leaves it.
        machine.succeed("systemctl stop 'max-job-*.service'")
        machine.succeed("systemctl is-active keep.service")
        # Gone from the directory, it is stopped and removed: by a
        # program, which has the tool by its name.
        machine.succeed("rm /work/.max/systemd/keep.service /work/.max/systemd/link.service")
        program = "const { tools } = require('${maxx}/lib/max-runner/tools.js'); (async () => console.log(JSON.stringify(await tools.units_apply())))()"
        applied = json.loads(machine.succeed(f"node -e {shlex.quote(program)}"))
        assert applied["removed"] == ["keep.service"] and applied["skipped"] == [], applied
        machine.fail("systemctl is-active keep.service")
        machine.succeed("sleep 2")
        assert len(wakes()) == 8, wakes()
  '';
}
