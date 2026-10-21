#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: create-manifest.sh <backup.zip>" >&2
    exit 2
fi

backup="$1"

if [ ! -f "$backup" ]; then
    echo "Backup file not found: $backup" >&2
    exit 1
fi

sha256="$(sha256sum "$backup" | awk '{print $1}')"
size="$(wc -c < "$backup" | tr -d ' ')"
filename="$(basename "$backup")"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

manifest="${backup}.manifest.json"
tmp="${manifest}.tmp"

printf '{\n  "schema_version": 1,\n  "filename": "%s",\n  "sha256": "%s",\n  "size_bytes": %s,\n  "created_at": "%s"\n}\n' \
    "$filename" "$sha256" "$size" "$created_at" > "$tmp"

mv "$tmp" "$manifest"
echo "$manifest"