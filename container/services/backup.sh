#!/bin/sh
set -eu

BACKUP_DIR="${AZURE_BACKUP_DIR:-/tmp/hermes-azure-backups}"
INTERVAL_SECONDS="${AZURE_BACKUP_INTERVAL_SECONDS:-900}"

mkdir -p "$BACKUP_DIR"

while :; do
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    archive="$BACKUP_DIR/hermes-${timestamp}-$$.zip"

    echo "[backup] Creating Hermes backup."

    if hermes backup -o "$archive"; then
        if /opt/hermes-azure/scripts/create-manifest.sh "$archive"; then
            if python3 /opt/hermes-azure/scripts/upload_blob.py "$archive"; then
                echo "[backup] Backup and manifest uploaded successfully."
            else
                echo "[backup] Upload failed; retaining local files for diagnosis." >&2
            fi
        else
            echo "[backup] Manifest generation failed." >&2
            rm -f "$archive"
        fi
    else
        echo "[backup] Hermes backup failed." >&2
        rm -f "$archive"
    fi

    echo "[backup] Next attempt in ${INTERVAL_SECONDS} seconds."
    sleep "$INTERVAL_SECONDS"
done