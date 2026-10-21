import sqlite3
import sys

db_path = sys.argv[1]

try:
    with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as db:
        db.execute("PRAGMA quick_check")
        result = db.execute("PRAGMA quick_check").fetchone()[0]
        if result != "ok":
            raise RuntimeError(result)

    print("OK: database SQLite leggibile e integro")
except Exception as exc:
    print(f"ERRORE: database SQLite non valido: {exc}")
    sys.exit(1)