#!/bin/sh
set -eu

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/data"

cat > "$TEST_DIR/bin/hermes" <<'STUB'
#!/bin/sh
echo "backup-attempt" >> "$TEST_LOG"
exit 1
STUB
chmod +x "$TEST_DIR/bin/hermes"

export TEST_LOG="$TEST_DIR/attempts.log"
export PATH="$TEST_DIR/bin:$PATH"
export AZURE_BACKUP_DIR="$TEST_DIR/data"
export AZURE_BACKUP_INTERVAL_SECONDS=1

# Il timeout interrompe il ciclo dopo aver dato modo di riprovare.
set +e
timeout 4 /bin/sh /opt/hermes-azure/services/backup.sh >"$TEST_DIR/output.log" 2>&1
status=$?
set -e

if [ "$status" -ne 124 ]; then
    cat "$TEST_DIR/output.log"
    echo "ERRORE: lo script è terminato inaspettatamente (status=$status)" >&2
    exit 1
fi

attempts="$(grep -c '^backup-attempt$' "$TEST_LOG" || true)"

cat "$TEST_DIR/output.log"

if [ "$attempts" -lt 2 ]; then
    echo "ERRORE: attesi almeno 2 tentativi, trovati $attempts" >&2
    exit 1
fi

echo "OK: il backup fallito viene ritentato"