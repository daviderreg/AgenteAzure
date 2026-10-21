#!/bin/sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
BACKUP_DIR="${AZURE_BACKUP_DIR:-/tmp/hermes-azure-backups}"
MARKER="$HERMES_HOME/.azure_restore_complete"

mkdir -p "$HERMES_HOME" "$BACKUP_DIR"

if [ -f "$MARKER" ]; then
    echo "[restore] Completion marker exists; skipping restore."
    exit 0
fi

# Capture the downloader output so an empty backup store is distinguishable
# from network, authentication, or storage errors.
download_output="$(
    python3 /opt/hermes-azure/scripts/download_backup.py
)" || {
    echo "[restore] Could not retrieve backup candidates; refusing startup." >&2
    exit 1
}

if [ "$download_output" = "NO_BACKUPS_FOUND" ]; then
    echo "[restore] Azure contains no backups; marking first boot as initialized."
    tmp="$MARKER.tmp"
    (umask 077; printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp")
    mv "$tmp" "$MARKER"
    exit 0
fi

# Try the newest backup, followed by exactly one previous backup.
for candidate in latest previous; do
    archive="$BACKUP_DIR/${candidate}.zip"
    manifest="${archive}.manifest.json"

    [ -f "$archive" ] || continue
    [ -f "$manifest" ] || {
        echo "[restore] Missing manifest for $candidate backup." >&2
        continue
    }

    if ! /opt/hermes-azure/scripts/verify-manifest.sh "$archive" "$manifest"; then
        echo "[restore] Integrity check failed for $candidate backup." >&2
        continue
    fi

    
    echo "[restore] Importing verified $candidate backup."

    import_log="$BACKUP_DIR/${candidate}-import.log"

    if hermes import --force "$archive" >"$import_log" 2>&1; then
        cat "$import_log"

        if grep -Eq 'Warnings \([1-9][0-9]* files skipped\):' "$import_log"; then
            echo "[restore] Hermes import reported skipped files for $candidate backup." >&2
            continue
        fi

        if [ ! -f "$HERMES_HOME/state.db" ]; then
            echo "[restore] state.db missing after import." >&2
            continue
        fi

        if ! /opt/hermes/.venv/bin/python \
            /opt/hermes-azure/scripts/check_sqlite.py \
            "$HERMES_HOME/state.db"; then
            echo "[restore] state.db integrity check failed." >&2
            continue
        fi

        tmp="$MARKER.tmp"
        (umask 077; printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp")
        mv "$tmp" "$MARKER"

        echo "[restore] Restore completed using $candidate backup."
        exit 0
    else
        cat "$import_log" >&2
        echo "[restore] Import failed for $candidate backup." >&2
    fi


done

echo "[restore] No backup could be restored; refusing startup." >&2
exit 1