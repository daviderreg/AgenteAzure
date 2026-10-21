#!/bin/sh
set -eu

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/home" "$TEST_ROOT/backups" "$TEST_ROOT/bin"

cp /opt/hermes-azure/scripts/restore.sh "$TEST_ROOT/scripts/restore.sh"
cp /opt/hermes-azure/scripts/verify-manifest.sh "$TEST_ROOT/scripts/verify-manifest.sh"

cat > "$TEST_ROOT/scripts/download_backup.py" <<'PY'
import hashlib
import json
import os
import zipfile
from pathlib import Path

directory = Path(os.environ["AZURE_BACKUP_DIR"])

for name in ("latest", "previous"):
    archive = directory / f"{name}.zip"
    with zipfile.ZipFile(archive, "w") as zf:
        zf.writestr("state.db", "simulated")
    manifest = {
        "schema_version": 1,
        "filename": archive.name,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "size_bytes": archive.stat().st_size,
    }
    (directory / f"{name}.zip.manifest.json").write_text(json.dumps(manifest))
PY

cat > "$TEST_ROOT/bin/hermes" <<'SH'
#!/bin/sh
set -eu
[ "$1" = "import" ] || exit 10
[ "$2" = "--force" ] || exit 11

case "$3" in
  */latest.zip)
    echo "Warnings (1 files skipped):"
    echo "  simulated/file: permission denied"
    exit 0
    ;;
  */previous.zip)
    /opt/hermes/.venv/bin/python -c '
import os, sqlite3
db = os.path.join(os.environ["HERMES_HOME"], "state.db")
con = sqlite3.connect(db)
con.execute("CREATE TABLE IF NOT EXISTS test (id INTEGER)")
con.commit()
con.close()
'
    exit 0
    ;;
  *) exit 12 ;;
esac
SH
chmod +x "$TEST_ROOT/bin/hermes"

sed \
  -e "s|/opt/hermes-azure/scripts/download_backup.py|$TEST_ROOT/scripts/download_backup.py|g" \
  -e "s|/opt/hermes-azure/scripts/verify-manifest.sh|$TEST_ROOT/scripts/verify-manifest.sh|g" \
  "$TEST_ROOT/scripts/restore.sh" > "$TEST_ROOT/scripts/restore-test.sh"
chmod +x "$TEST_ROOT/scripts/restore-test.sh"

PATH="$TEST_ROOT/bin:$PATH" \
HERMES_HOME="$TEST_ROOT/home" \
AZURE_BACKUP_DIR="$TEST_ROOT/backups" \
sh "$TEST_ROOT/scripts/restore-test.sh"

[ -f "$TEST_ROOT/home/state.db" ] || { echo "ERRORE: state.db assente" >&2; exit 1; }
[ -f "$TEST_ROOT/home/.azure_restore_complete" ] || { echo "ERRORE: marker assente" >&2; exit 1; }

echo "OK: warning rilevato e backup precedente ripristinato"
