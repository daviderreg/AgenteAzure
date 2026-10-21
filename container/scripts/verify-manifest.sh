#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: verify-manifest.sh <backup.zip> <manifest.json>" >&2
    exit 2
fi

backup="$1"
manifest="$2"

[ -f "$backup" ] || { echo "Backup file not found" >&2; exit 1; }
[ -f "$manifest" ] || { echo "Manifest file not found" >&2; exit 1; }

expected_hash="$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print(data["sha256"])
' "$manifest")"

expected_size="$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print(data["size_bytes"])
' "$manifest")"

actual_hash="$(sha256sum "$backup" | awk '{print $1}')"
actual_size="$(wc -c < "$backup" | tr -d ' ')"

if [ "$actual_hash" != "$expected_hash" ]; then
    echo "SHA-256 mismatch" >&2
    exit 1
fi

if [ "$actual_size" != "$expected_size" ]; then
    echo "File size mismatch" >&2
    exit 1
fi

python3 - "$backup" <<'PY'
import sys
import zipfile

path = sys.argv[1]
if not zipfile.is_zipfile(path):
    raise SystemExit("Backup is not a valid ZIP archive")

with zipfile.ZipFile(path) as z:
    bad = z.testzip()
    if bad is not None:
        raise SystemExit(f"Corrupt ZIP member: {bad}")
PY

echo "Backup integrity verified"
