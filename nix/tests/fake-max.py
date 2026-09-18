import json
import os
import signal
import sys

config_path = sys.argv[sys.argv.index("--config-file") + 1]
with open(config_path, encoding="utf-8") as handle:
    config = json.load(handle)
with open(os.path.join(os.environ["RUNTIME_DIRECTORY"], "persona"), "w", encoding="utf-8") as handle:
    handle.write(config["persona"])

signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(0))
while True:
    signal.pause()
