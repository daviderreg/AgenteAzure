import importlib.util
import signal
import sys
from pathlib import Path

SUPERVISOR = Path("/opt/hermes-azure/services/supervisor.py")

spec = importlib.util.spec_from_file_location("supervisor", SUPERVISOR)
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

# Processo fittizio che ignora SIGTERM.
import subprocess

process = subprocess.Popen(
    [
        sys.executable,
        "-u",
        "-c",
        "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('READY', flush=True); time.sleep(60)",
    ],
    start_new_session=True,
    stdout=subprocess.PIPE,
    text=True,
)

assert process.stdout.readline().strip() == "READY", "Processo non pronto"
supervisor.children["fake"] = process

# stop_children deve attendere il timeout e poi usare SIGKILL.
supervisor.stop_children()

assert process.poll() is not None, "Il processo è ancora attivo"
assert process.returncode == -signal.SIGKILL, (
    f"Atteso SIGKILL, ricevuto returncode={process.returncode}"
)

print("OK: processo che ignora SIGTERM terminato con SIGKILL")