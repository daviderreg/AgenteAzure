import os
import subprocess
import sys
import tempfile
from pathlib import Path

SUPERVISOR = Path("/opt/hermes-azure/services/supervisor.py")

with tempfile.TemporaryDirectory() as temp:
    temp = Path(temp)
    gateway = temp / "gateway.py"
    backup = temp / "backup.py"
    marker = temp / "backup-starts.txt"

    gateway.write_text(
        "import time\n"
        "time.sleep(60)\n"
    )

    backup.write_text(
        "import os, pathlib, sys\n"
        "p = pathlib.Path(os.environ['TEST_MARKER'])\n"
        "with p.open('a') as f:\n"
        "    f.write('start\\n')\n"
        "if p.read_text().count('start') == 1:\n"
        "    sys.exit(1)\n"
        "import time\n"
        "time.sleep(60)\n"
    )

    env = os.environ.copy()
    env["HERMES_GATEWAY_COMMAND"] = f"{sys.executable} {gateway}"
    env["HERMES_BACKUP_COMMAND"] = f"{sys.executable} {backup}"
    env["HERMES_BACKUP_RESTART_DELAY"] = "1"
    env["TEST_MARKER"] = str(marker)

    process = subprocess.Popen(
        [sys.executable, str(SUPERVISOR)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    try:
        # Aspetta fino a 10 secondi il secondo avvio del backup.
        import time
        deadline = time.monotonic() + 10

        while time.monotonic() < deadline:
            if marker.exists() and marker.read_text().count("start") >= 2:
                break
            if process.poll() is not None:
                raise AssertionError("Il supervisore è terminato inaspettatamente")
            time.sleep(0.1)

        starts = marker.read_text().count("start") if marker.exists() else 0
        assert starts >= 2, f"Backup non riavviato: {starts} avvii"

        print("OK: backup riavviato automaticamente")
    finally:
        process.terminate()
        try:
            process.wait(timeout=25)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

        output = process.stdout.read() if process.stdout else ""
        print(output, end="")