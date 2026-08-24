import json
import os
import signal
import socket
import sys


config_path = sys.argv[sys.argv.index("--config-file") + 1]
runtime_dir = os.environ["RUNTIME_DIRECTORY"]
socket_path = os.path.join(runtime_dir, "control.sock")
generation_path = os.path.join(runtime_dir, "generation")
generation = 1


def write_generation():
    with open(generation_path, "w", encoding="utf-8") as handle:
        handle.write(str(generation))


def stop(_signum, _frame):
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    os.unlink(socket_path)
except FileNotFoundError:
    pass

listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(socket_path)
os.chmod(socket_path, 0o600)
listener.listen(16)
write_generation()

while True:
    connection, _ = listener.accept()
    with connection:
        request = json.loads(connection.makefile("rb").readline())
        with open(config_path, "r", encoding="utf-8") as handle:
            candidate = handle.read()
        old = generation
        if request.get("rrProtocol") != 1 or request.get("rrCommand") != "reload":
            response = {
                "rpOk": False,
                "rpOldGeneration": old,
                "rpNewGeneration": old,
                "rpChangedFields": [],
                "rpRestartFields": [],
                "rpError": "ReloadInvalidRequest",
            }
        elif "invalid_reload: true" in candidate:
            response = {
                "rpOk": False,
                "rpOldGeneration": old,
                "rpNewGeneration": old,
                "rpChangedFields": [],
                "rpRestartFields": [],
                "rpError": "ReloadConfigInvalid",
            }
        else:
            generation += 1
            write_generation()
            response = {
                "rpOk": True,
                "rpOldGeneration": old,
                "rpNewGeneration": generation,
                "rpChangedFields": ["persona"],
                "rpRestartFields": [],
                "rpError": None,
            }
        connection.sendall(json.dumps(response).encode("utf-8") + b"\n")
