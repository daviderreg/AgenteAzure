#!/bin/sh
set -eu

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/home" "$TEST_ROOT/backups" "$TEST_ROOT/bin"

cp /opt/hermes-azure/scripts/restore.sh "$TEST_ROOT/scripts/restore.sh"
cp /opt/hermes-azure/scripts/verify-manifest.sh "$TEST_ROOT/scripts/verify-manifest.sh"

cat > "$TEST_ROOT/scripts/download_backup.py" <<'PY'
import json
import os
import zipfile
from pathlib import Path

directory = Path(os.environ["AZURE_BACKUP_DIR"])
directory.mkdir(parents=True, exist_ok=True)

# Latest: a ZIP with a deliberately incorrect manifest hash.
latest = directory / "latest.zip"
latest.write_bytes(b"not-a-valid-backup")
(directory / "latest.zip.manifest.json").write_text(json.dumps({
    "schema_version": 1,
    "filename": "latest.zip",
    "sha256": "0" * 64,
    "size_bytes": latest.stat().st_size
}))

# Previous: a valid ZIP with a manifest matching its bytes.
previous = directory / "previous.zip"
with zipfile.ZipFile(previous, "w") as archive:
    archive.writestr("state.db", "simulated state")
manifest = {
    "schema_version": 1,
    "filename": "previous.zip",
    "sha256": __import__("hashlib").sha256(previous.read_bytes()).hexdigest(),
    "size_bytes": previous.stat().st_size
}
(directory / "previous.zip.manifest.json").write_text(json.dumps(manifest))
PY

cat > "$TEST_ROOT/bin/hermes" <<'SH'
#!/bin/sh
set -eu
[ "$1" = "import" ] || exit 10
[ "$2" = "--force" ] || exit 11
case "$3" in
  */previous.zip) touch "$HERMES_HOME/state.db"; exit 0 ;;
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

echo "OK: latest non valido scartato e previous ripristinato"
