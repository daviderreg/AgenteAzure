#!/bin/sh
set -eu

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/home" "$TEST_ROOT/bin"

cp /opt/hermes-azure/scripts/restore.sh "$TEST_ROOT/scripts/restore.sh"

cat > "$TEST_ROOT/scripts/download_backup.py" <<'PY'
print("NO_BACKUPS_FOUND")
PY

# Redirect the production script's fixed paths into the test directory.
sed \
  -e "s|/opt/hermes-azure/scripts/download_backup.py|$TEST_ROOT/scripts/download_backup.py|g" \
  -e "s|/opt/hermes-azure/scripts/verify-manifest.sh|$TEST_ROOT/scripts/verify-manifest.sh|g" \
  "$TEST_ROOT/scripts/restore.sh" > "$TEST_ROOT/scripts/restore-test.sh"

chmod +x "$TEST_ROOT/scripts/restore-test.sh"


HERMES_HOME="$TEST_ROOT/home" \
AZURE_BACKUP_DIR="$TEST_ROOT/backups" \
sh "$TEST_ROOT/scripts/restore-test.sh"

if [ ! -f "$TEST_ROOT/home/.azure_restore_complete" ]; then
  echo "ERRORE: marker non creato senza backup" >&2
  exit 1
fi

echo "OK: primo avvio senza backup, marker creato"

# Il secondo avvio deve saltare il ripristino grazie al marker.
second_output="$(
  HERMES_HOME="$TEST_ROOT/home" \
  AZURE_BACKUP_DIR="$TEST_ROOT/backups" \
  sh "$TEST_ROOT/scripts/restore-test.sh"
)"

printf '%s\n' "$second_output"

case "$second_output" in
  *"Completion marker exists; skipping restore."*)
    echo "OK: secondo avvio, ripristino saltato"
    ;;
  *)
    echo "ERRORE: il secondo avvio non ha saltato il ripristino" >&2
    exit 1
    ;;
esac
