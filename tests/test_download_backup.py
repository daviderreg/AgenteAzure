import importlib.util
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path("/opt/hermes-azure/scripts/download_backup.py")
spec = importlib.util.spec_from_file_location("download_backup", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def make_backup(name, state_db=True):
    import io
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        if state_db:
            archive.writestr("state.db", b"test database")
        else:
            archive.writestr("config.yaml", "test: true")
    content = buffer.getvalue()
    manifest = {
        "schema_version": 1,
        "filename": name,
        "sha256": hashlib.sha256(content).hexdigest(),
        "size_bytes": len(content),
    }
    return content, json.dumps(manifest).encode()

def run_test():
    valid_name = "auto/hermes-20261007T120000Z-123.zip"
    bad_hash_name = "auto/hermes-20261009T120000Z-456.zip"
    missing_manifest_name = "auto/hermes-20261010T120000Z-789.zip"

    valid_backup = make_backup("hermes-20261007T120000Z-123.zip")
    bad_hash_backup = make_backup("hermes-20261009T120000Z-456.zip")

    bad_hash_manifest = json.loads(bad_hash_backup[1])
    bad_hash_manifest["sha256"] = "0" * 64

    blobs = {
        missing_manifest_name: make_backup(
        "hermes-20261010T120000Z-789.zip"
    ),
        bad_hash_name: bad_hash_backup,
        valid_name: valid_backup,
    }

    manifests = {
        bad_hash_name + ".manifest.json": json.dumps(
            bad_hash_manifest
        ).encode(),
        valid_name + ".manifest.json": valid_backup[1],
        # Intentionally no manifest for missing_manifest_name.
    }

    names = [
        missing_manifest_name,
        bad_hash_name,
        valid_name,
    ]

    def fake_request(url, bearer):
        for name, content in blobs.items():
            if url.endswith("/" + name):
                return content[0]
        for name, content in manifests.items():
            if url.endswith("/" + name):
                return content
        from urllib.error import HTTPError
        raise HTTPError(url, 404, "Not Found", {}, None)

    with tempfile.TemporaryDirectory() as tmp:
        env = {
            "AZURE_STORAGE_ACCOUNT": "testaccount",
            "AZURE_STORAGE_CONTAINER": "testcontainer",
            "AZURE_BACKUP_PREFIX": "auto",
            "AZURE_BACKUP_DIR": tmp,
        }

        with patch.dict(os.environ, env, clear=False), \
             patch.object(module, "managed_identity_token",
                          return_value="fake-token"), \
             patch.object(module, "list_backup_blobs",
                          return_value=names), \
             patch.object(module, "azure_request",
                          side_effect=fake_request), \
             patch("sys.argv", ["download_backup.py"]):
            result = module.main()

        assert result == 0, f"Expected exit code 0, got {result}"

        folder = Path(tmp)
        assert (folder / "latest.zip").exists()
        assert not (folder / "previous.zip").exists()

        with zipfile.ZipFile(folder / "latest.zip") as archive:
            assert "state.db" in archive.namelist()

        assert not (
            folder / "candidate-hermes-20261009T120000Z-456.zip"
        ).exists()
        assert not (
            folder / "candidate-hermes-20261010T120000Z-789.zip"
        ).exists()

        print("OK: manifest mancante scartato")
        print("OK: hash SHA-256 errato scartato")
        print("OK: backup valido successivo recuperato")

def test_unrecognized_zip_is_not_empty():
    with tempfile.TemporaryDirectory() as tmp:
        env = {
            "AZURE_STORAGE_ACCOUNT": "testaccount",
            "AZURE_STORAGE_CONTAINER": "testcontainer",
            "AZURE_BACKUP_PREFIX": "auto",
            "AZURE_BACKUP_DIR": tmp,
        }

        with patch.dict(os.environ, env, clear=False), \
             patch.object(module, "managed_identity_token",
                          return_value="fake-token"), \
             patch.object(module, "list_backup_blobs",
                          return_value=["auto/legacy-backup.zip"]), \
             patch.object(module, "azure_request",
                          side_effect=AssertionError(
                              "Unrecognized ZIP must not be downloaded"
                          )), \
             patch("sys.argv", ["download_backup.py"]):
            result = module.main()

        assert result == 1, (
            f"Expected exit code 1 for unrecognized backup, got {result}"
        )

        print("OK: backup non riconosciuto non viene trattato come storage vuoto")        

if __name__ == "__main__":
    run_test()
    test_unrecognized_zip_is_not_empty()
