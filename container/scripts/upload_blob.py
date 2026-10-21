#!/usr/bin/env python3
"""Upload a Hermes backup and its manifest to Azure Blob Storage."""

import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable is missing: {name}")
    return value


def managed_identity_token() -> str:
    endpoint = required_env("IDENTITY_ENDPOINT")
    identity_header = required_env("IDENTITY_HEADER")

    url = (
        f"{endpoint}?api-version=2019-08-01"
        "&resource=https%3A%2F%2Fstorage.azure.com%2F"
    )
    request = Request(url, headers={"X-IDENTITY-HEADER": identity_header})

    with urlopen(request, timeout=20) as response:
        payload = json.load(response)

    token = payload.get("access_token")
    if not token:
        raise RuntimeError("Managed Identity did not return an access token")
    return token


def put_blob(
    url: str,
    token: str,
    content: bytes,
    content_type: str,
    metadata: dict[str, str] | None = None,
) -> None:
    headers = {
        "Authorization": f"Bearer {token}",
        "x-ms-version": "2023-11-03",
        "x-ms-date": datetime.now(timezone.utc).strftime(
            "%a, %d %b %Y %H:%M:%S GMT"
        ),
        "x-ms-blob-type": "BlockBlob",
        "Content-Type": content_type,
        "Content-Length": str(len(content)),
    }

    if metadata:
        headers.update(
            {f"x-ms-meta-{key.lower()}": value for key, value in metadata.items()}
        )

    request = Request(url, data=content, headers=headers, method="PUT")
    with urlopen(request, timeout=180) as response:
        if response.status not in (200, 201):
            raise RuntimeError(f"Unexpected Blob Storage HTTP status: {response.status}")


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: upload_blob.py <backup.zip>", file=sys.stderr)
        return 2

    backup = Path(sys.argv[1]).resolve()
    manifest_path = Path(f"{backup}.manifest.json")

    if not backup.is_file() or not manifest_path.is_file():
        raise RuntimeError("Backup or its manifest is missing")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    content = backup.read_bytes()
    digest = hashlib.sha256(content).hexdigest()

    if digest != manifest.get("sha256"):
        raise RuntimeError("Backup SHA-256 does not match its manifest")
    if len(content) != manifest.get("size_bytes"):
        raise RuntimeError("Backup size does not match its manifest")

    account = required_env("AZURE_STORAGE_ACCOUNT")
    container = required_env("AZURE_STORAGE_CONTAINER")
    prefix = os.environ.get("AZURE_BACKUP_PREFIX", "auto").strip("/")

    # Keep each backup's ZIP and manifest together under a predictable prefix.
    blob_name = "/".join(part for part in (prefix, backup.name) if part)
    manifest_name = f"{blob_name}.manifest.json"
    base_url = f"https://{account}.blob.core.windows.net/{quote(container, safe='')}"
    token = managed_identity_token()

    # Upload the archive first. Publish its manifest only after the archive succeeds.
    put_blob(
        f"{base_url}/{quote(blob_name, safe='/')}",
        token,
        content,
        "application/zip",
        {"sha256": digest},
    )

    manifest_bytes = manifest_path.read_bytes()
    put_blob(
        f"{base_url}/{quote(manifest_name, safe='/')}",
        token,
        manifest_bytes,
        "application/json",
    )

    print(f"Uploaded backup: {blob_name}")
    print(f"SHA-256: {digest}")
    print(f"Size: {len(content)} bytes")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (HTTPError, URLError, OSError, ValueError, RuntimeError) as exc:
        # Never print request headers or tokens.
        print(f"Blob upload failed: {exc}", file=sys.stderr)
        raise SystemExit(1)