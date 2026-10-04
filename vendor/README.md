# Vendored SQLite3 amalgamation

Version: 3.50.4 (2025-11-11) — update this line on every drop.
Upstream: https://sqlite.org/download.html ("amalgamation" zip).

Upgrade procedure: replace `sqlite3.c` + `sqlite3.h` wholesale, update the
version line above, run `zig build test`. Never hand-edit either file.
Compile flags (in build.zig): -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_JOURNAL_MODE=WAL -DSQLITE_DEFAULT_SYNCHRONOUS=1 (=NORMAL) -DSQLITE_OMIT_LOAD_EXTENSION (storage-v2 §11.1).
