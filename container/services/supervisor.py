#!/opt/hermes/.venv/bin/python
import os
import signal
import subprocess
import sys
import time

children = {}
stopping = False

GATEWAY_COMMAND = os.environ.get(
    "HERMES_GATEWAY_COMMAND",
    "hermes gateway run",
).split()

BACKUP_COMMAND = os.environ.get(
    "HERMES_BACKUP_COMMAND",
    "/bin/sh /opt/hermes-azure/services/backup.sh",
).split()

BACKUP_RESTART_DELAY = float(
    os.environ.get("HERMES_BACKUP_RESTART_DELAY", "5")
)

def handle_signal(signum, _frame):
    global stopping
    stopping = True
    print(f"[supervisor] Signal {signum} received; stopping children.", flush=True)


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def start(name, command):
    process = subprocess.Popen(command, start_new_session=True)
    children[name] = process
    print(f"[supervisor] Started {name} (pid={process.pid}).", flush=True)


def stop_children():
    for name, process in list(children.items()):
        if process.poll() is None:
            print(f"[supervisor] Sending SIGTERM to {name}.", flush=True)
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    deadline = time.monotonic() + 20

    for name, process in list(children.items()):
        if process.poll() is None:
            remaining = max(0, deadline - time.monotonic())
            try:
                process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                print(
                    f"[supervisor] {name} did not stop; sending SIGKILL.",
                    flush=True,
                )
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()


def main():
    start("gateway", GATEWAY_COMMAND)
    start("backup", BACKUP_COMMAND)

    try:
        while not stopping:
            for name, process in list(children.items()):
                result = process.poll()
                if result is not None:
                    print(
                        f"[supervisor] {name} exited with code {result}.",
                        flush=True,
                    )
                    if name == "backup":
                        # Backup failures must not stop the gateway.
                        print(
                            f"[supervisor] Backup service exited; restarting it in {BACKUP_RESTART_DELAY:g} seconds.",
                            flush=True,
                        )
                        deadline = time.monotonic() + BACKUP_RESTART_DELAY
                        while not stopping and time.monotonic() < deadline:
                            time.sleep(0.1)

                        if not stopping:
                            start("backup", BACKUP_COMMAND)

                    else:
                        # The gateway is the primary service.
                        return result
            time.sleep(1)
    finally:
        stop_children()

    return 0


if __name__ == "__main__":
    sys.exit(main())