#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
hub_binary="${1:?usage: test-maxops.sh /path/to/maxops-hub}"
python3 - "$hub_binary" <<'PY'
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time

agent_token = secrets.token_hex(32)
execution_token = secrets.token_hex(32)

class Agent(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        if self.path == "/v1/manage" and self.headers.get("Authorization") == f"Bearer {execution_token}":
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if request["action"] != "logs":
                self.send_error(404)
                return
            body = json.dumps({"result": "logs", "value": {
                "job_id": request["params"]["job_id"], "encoding": "base64",
                "stdout_base64": "aGkK", "stderr_base64": "/w==",
                "next_stdout_offset": 3, "next_stderr_offset": 1,
                "complete": True, "truncated": False}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path != "/v1/unit" or self.headers.get("Authorization") != f"Bearer {agent_token}":
            self.send_error(401)
            return
        params = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert params == {"host": "fixture", "unit": "fixture.service"}
        body = json.dumps({"host": "fixture", "observed_at": datetime.now(timezone.utc).isoformat(),
                           "unit": {"unit": "fixture.service", "description": "synthetic service", "load_state": "loaded", "active_state": "failed", "sub_state": "failed",
                                    "details": {"main_pid": 0, "memory_current_bytes": None, "restarts": 1, "exec_main_code": 1, "exec_main_status": 1}}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/v1/snapshot" or self.headers.get("Authorization") != f"Bearer {agent_token}":
            self.send_error(401)
            return
        body = json.dumps({
            "host": "fixture", "observed_at": datetime.now(timezone.utc).isoformat(),
            "facts": {"kernel": "fixture", "uptime_seconds": 12.0, "system_closure": None},
            "units": [{"unit": "fixture.service", "description": "synthetic service",
                       "load_state": "loaded", "active_state": "failed", "sub_state": "failed"}],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

with tempfile.TemporaryDirectory(prefix="max-maxops-acceptance-") as directory:
    root = Path(directory)
    for name, token in [("agent", agent_token), ("execution", execution_token), ("client", secrets.token_hex(32)), ("manager", secrets.token_hex(32))]:
        path = root / name
        path.write_text(token)
        path.chmod(0o600)
    agent = ThreadingHTTPServer(("127.0.0.1", 0), Agent)
    threading.Thread(target=agent.serve_forever, daemon=True).start()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    config = {
        "listen": f"127.0.0.1:{port}",
        "state_file": str(root / "hub.db"),
        "hosts": [{"name": "fixture", "agent_url": f"http://127.0.0.1:{agent.server_port}",
                   "agent_token_file": str(root / "agent"), "execution_token_file": str(root / "execution"),
                   "readable_units": ["fixture.service"], "manageable_units": ["fixture.service"]}],
        "clients": [{"name": "max", "token_file": str(root / "client"), "hosts": ["fixture"],
                     "capabilities": ["fleet:read", "host:read", "units:read", "metrics:read"]},
                    {"name": "max-manager", "token_file": str(root / "manager"), "hosts": ["fixture"],
                     "access": "manage", "capabilities": ["fleet:read", "host:read", "units:read", "metrics:read",
                     "diagnostics:collect", "remediations:manage", "jobs:read", "jobs:cancel", "events:read", "self:read",
                     "alerts:read", "changes:read", "deploy:manage", "exec:run", "logs:read", "units:manage",
                     "workspace:publish", "workspace:read", "workspace:write"]}],
    }
    path = root / "hub.json"
    path.write_text(json.dumps(config))
    hub = subprocess.Popen([sys.argv[1], "--config", str(path)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    endpoint = f"http://127.0.0.1:{port}"
    try:
        for _ in range(100):
            if hub.poll() is not None:
                raise RuntimeError("hub exited before readiness")
            try:
                with urlopen(endpoint + "/healthz", timeout=1) as response:
                    if response.status == 200:
                        break
            except URLError:
                time.sleep(0.05)
        else:
            raise RuntimeError("hub readiness timeout")
        if fixture := os.environ.get("MAXOPS_CATALOG_FIXTURE"):
            request = Request(endpoint + "/v1/operations?view=tools", headers={"Authorization": "Bearer " + (root / "manager").read_text()})
            with urlopen(request, timeout=5) as response:
                Path(fixture).write_text(json.dumps(json.load(response), ensure_ascii=False, indent=2) + "\n")
        environment = dict(os.environ)
        environment.update({"http_proxy": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1",
                            "https_proxy": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1",
                            "no_proxy": "", "NO_PROXY": ""})
        subprocess.run(["cabal", "exec", "--", "runghc", "-package=max", "scripts/test-maxops.hs",
                        endpoint, str(root / "client"), "fixture", "fixture.service"],
                       env=environment, check=True)
        subprocess.run(["cabal", "exec", "--", "runghc", "-package=max", "scripts/test-maxops.hs",
                        endpoint, str(root / "manager"), "fixture", "fixture.service", "--management"],
                       env=environment, check=True)
        print("PASS real Rust hub + Max query/management runners, durable jobs and synthetic agent")
    finally:
        hub.terminate()
        try:
            hub.wait(timeout=5)
        except subprocess.TimeoutExpired:
            hub.kill()
            hub.wait()
        agent.shutdown()
        agent.server_close()
PY
