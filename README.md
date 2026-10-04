# rime

A build tool that shares build artifacts across projects through one
bounded, content-addressed store — instead of growing a `target/` directory
until the disk fills.

## Status

Storage core (Tasks 1–13 of docs/superpowers/plans/2026-10-04-storage-core.md).
Design: docs/design/storage.md.

## Commands

    rime cache stat                 # usage vs limits, roots, binding constraint
    rime gc [--dry-run] [--to-size 5GiB] [--older-than 7d]
    rime pin <name> <digest>        # keep an object through gc
    rime unpin <name>
    rime store put <name> <file>    # durable storage (ingest + pin)
    rime store get <name> <out>
    rime cache verify               # sample and re-hash stored objects

## Build

    zig build test
    zig build

Zig 0.16.0, macOS + Linux. Limits configurable per docs/design/storage.md §10.
