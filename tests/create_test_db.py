import sqlite3

with sqlite3.connect("/tmp/state.db") as db:
    db.execute("CREATE TABLE IF NOT EXISTS test (id INTEGER)")

print("DATABASE_CREATO")