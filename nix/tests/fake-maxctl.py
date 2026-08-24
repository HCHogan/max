import json
import socket
import sys


path = sys.argv[sys.argv.index("--socket") + 1]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.connect(path)
client.sendall(json.dumps({"rrProtocol": 1, "rrCommand": "reload"}).encode("utf-8") + b"\n")
response = json.loads(client.makefile("rb").readline())
if not response["rpOk"]:
    raise SystemExit(1)
