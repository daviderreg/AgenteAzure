#!/usr/bin/env python3
"""Download the two newest usable Hermes backups from Azure Blob Storage."""

import json
import hashlib
import zipfile
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


BACKUP_NAME_RE = re.compile(
    r"^hermes-(\d{8}T\d{6}Z)(?:-\d+)?\.zip$"
)


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if not value:
        raise RuntimeError(f"Missing environment variable: {name}")
    return value


def managed_identity_token() -> str:
    endpoint = env("IDENTITY_ENDPOINT")
    identity_header = env("IDENTITY_HEADER")

    query = urlencode({
        "api-version": "2019-08-01",
        "resource": "https://storage.azure.com/",
    })
    request = Request(
        f"{endpoint}?{query}",
        headers={"X-IDENTITY-HEADER": identity_header},
    )

    with urlopen(request, timeout=20) as response:
        payload = json.load(response)

    access_token = payload.get("access_token")
    if not access_token:
        raise RuntimeError("Managed Identity token unavailable")

    return access_token


def azure_request(url: str, bearer: str) -> bytes:
    request = Request(
        url,
        headers={
            "Authorization": f"Bearer {bearer}",
            "x-ms-version": "2023-11-03",
            "x-ms-date": datetime.now(timezone.utc).strftime(
                "%a, %d %b %Y %H:%M:%S GMT"
            ),
        },
    )

    with urlopen(request, timeout=180) as response:
        return response.read()


def list_backup_blobs(base_url: str, prefix: str, bearer: str) -> list[str]:
    """List all blobs under the backup prefix, following continuation markers."""
    names = []
    marker = None

    while True:
        params = {
            "restype": "container",
            "comp": "list",
            "prefix": f"{prefix}/" if prefix else "",
        }
        if marker:
            params["marker"] = marker

        url = f"{base_url}?{urlencode(params)}"
        root = ET.fromstring(azure_request(url, bearer))

        for element in root.findall(".//{*}Blob"):
            name = element.findtext("{*}Name", "")
            if name:
                names.append(name)

        marker = root.findtext("{*}NextMarker")
        if not marker:
            break

    # Fixed-width UTC timestamps sort chronologically as strings.
    return sorted(names, key=lambda name: name.rsplit("/", 1)[-1], reverse=True)


def download_atomically(url: str, bearer: str, destination: Path) -> None:
    temporary = Path(f"{destination}.tmp")
    try:
        temporary.write_bytes(azure_request(url, bearer))
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 1:
        print("Usage: download_backup.py", file=sys.stderr)
        return 2

    account = env("AZURE_STORAGE_ACCOUNT")
    container = env("AZURE_STORAGE_CONTAINER")
    prefix = env("AZURE_BACKUP_PREFIX", "auto").strip("/")
    destination = Path(env("AZURE_BACKUP_DIR", "/tmp/hermes-azure-backups"))
    destination.mkdir(parents=True, exist_ok=True)

    # Remove stale candidates so a failed download cannot reuse old files.
    for filename in (
        "latest.zip",
        "latest.zip.manifest.json",
        "previous.zip",
        "previous.zip.manifest.json",
    ):
        (destination / filename).unlink(missing_ok=True)

    base_url = (
        f"https://{account}.blob.core.windows.net/"
        f"{quote(container, safe='')}"
    )
    bearer = managed_identity_token()
    blob_names = list_backup_blobs(base_url, prefix, bearer)

    selected = []

    for name in blob_names:
        if len(selected) == 2:
            break

        basename = name.rsplit("/", 1)[-1]

        # Ignore manifests and other non-ZIP blobs.
        if not basename.lower().endswith(".zip"):
            continue

        # Do not silently treat unrecognized ZIPs as an empty store.
        if not BACKUP_NAME_RE.fullmatch(basename):
            print(
                f"Skipping backup with unrecognized filename: {basename}",
                file=sys.stderr,
            )
            continue

        blob_url = f"{base_url}/{quote(name, safe='/')}"
        manifest_url = f"{blob_url}.manifest.json"

        # A ZIP without its manifest is not a usable candidate.
        try:
            manifest_bytes = azure_request(manifest_url, bearer)
        except HTTPError as exc:
            if exc.code == 404:
                print(
                    f"Skipping backup without manifest: "
                    f"{name.rsplit('/', 1)[-1]}",
                    file=sys.stderr,
                )
                continue
            raise

        manifest = json.loads(manifest_bytes)

        if manifest.get("schema_version") != 1:
            print(f"Skipping unsupported manifest: {name}", file=sys.stderr)
            continue

        if manifest.get("filename") != basename:
            print(f"Skipping mismatched manifest: {basename}", file=sys.stderr)
            continue

        target_name = "latest.zip" if not selected else "previous.zip"
        zip_path = destination / target_name
        candidate_path = destination / f"candidate-{basename}"
        manifest_path = Path(f"{zip_path}.manifest.json")

        # Download the ZIP to a temporary file and publish it atomically.
        download_atomically(blob_url, bearer, candidate_path)
        actual_hash = hashlib.sha256(candidate_path.read_bytes()).hexdigest()
        if actual_hash != manifest.get("sha256"):
            candidate_path.unlink(missing_ok=True)
            print(f"Skipping backup with SHA-256 mismatch: {basename}", file=sys.stderr)
            continue

        actual_size = candidate_path.stat().st_size
        if actual_size != manifest.get("size_bytes"):
            candidate_path.unlink(missing_ok=True)
            print(f"Skipping backup with size mismatch: {basename}", file=sys.stderr)
            continue

        try:
            with zipfile.ZipFile(candidate_path) as archive:
                bad_member = archive.testzip()
                if bad_member is not None:
                    raise zipfile.BadZipFile(
                        f"Corrupt ZIP member: {bad_member}"
                    )
        except zipfile.BadZipFile as exc:
            candidate_path.unlink(missing_ok=True)
            print(f"Skipping invalid ZIP {basename}: {exc}", file=sys.stderr)
            continue

        with zipfile.ZipFile(candidate_path) as archive:
            if not any(
                member.endswith("state.db")
                for member in archive.namelist()
            ):
                candidate_path.unlink(missing_ok=True)
                print(f"Skipping backup without state.db: {basename}", file=sys.stderr)
                continue

        manifest_tmp = Path(f"{manifest_path}.tmp")
        try:
            os.replace(candidate_path, zip_path)
            manifest_tmp.write_bytes(manifest_bytes)
            os.replace(manifest_tmp, manifest_path)
        finally:
            manifest_tmp.unlink(missing_ok=True)

        selected.append(name)
        print(f"Downloaded candidate {len(selected)}: {basename}")

    if not selected:
        if not blob_names:
            print("NO_BACKUPS_FOUND")
            return 0

        print(
            "Backups exist, but no usable backup candidates were found.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        # Do not print tokens or request headers.
        print(f"Backup download failed: {exc}", file=sys.stderr)
        raise SystemExit(1)