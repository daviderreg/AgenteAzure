#!/bin/sh
set -eu

TEST_DIR="$(mktemp -d)"
SUPERVISOR="/opt/hermes-azure/services/supervisor.py"
PYTHON="/opt/hermes/.venv/bin/python"

cleanup() {
    if [ -n "${SUPERVISOR_PID:-}" ]; then
        kill -KILL "$SUPERVISOR_PID" 2>/dev/null || true
        wait "$SUPERVISOR_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

cat > "$TEST_DIR/child.py" <<'PY'
import signal
import sys
import time
from pathlib import Path

Path(sys.argv[1]).write_text(str(__import__("os").getpid()))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    time.sleep(0.2)
PY

export HERMES_GATEWAY_COMMAND="$PYTHON $TEST_DIR/child.py $TEST_DIR/gateway.pid"
export HERMES_BACKUP_COMMAND="$PYTHON $TEST_DIR/child.py $TEST_DIR/backup.pid"

"$PYTHON" "$SUPERVISOR" >"$TEST_DIR/supervisor.log" 2>&1 &
SUPERVISOR_PID=$!

attempt=0
while [ "$attempt" -lt 50 ]; do
    if [ -s "$TEST_DIR/gateway.pid" ] && [ -s "$TEST_DIR/backup.pid" ]; then
        break
    fi
    if ! kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
        cat "$TEST_DIR/supervisor.log"
        echo "ERRORE: il supervisore ? terminato inaspettatamente" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

if [ ! -s "$TEST_DIR/gateway.pid" ] || [ ! -s "$TEST_DIR/backup.pid" ]; then
    cat "$TEST_DIR/supervisor.log"
    echo "ERRORE: i processi fittizi non sono stati avviati" >&2
    exit 1
fi

kill -TERM "$SUPERVISOR_PID"
wait "$SUPERVISOR_PID"
SUPERVISOR_PID=""

cat "$TEST_DIR/supervisor.log"

echo "OK: il supervisore termina dopo SIGTERM"
