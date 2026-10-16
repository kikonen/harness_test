# SessionFileCache: digest cache design

Design notes for `lib/session_file_cache.rb` - the per-session digest cache
behind the "changed externally" error a write/patch can return.

---

## What it replaces

The model-facing SHA protocol: the model used to carry a `sha256` parameter
between `file.read` and `file.write` / `file.patch`. The digests are now
harness-side state kept in ONE place, so the model no longer transports them.

## Purpose

Detect a conflict with EXTERNAL changes made after the model read a file (a
user edit, another tool, generated code), so a stale write/patch fails with a
clear error instead of silently clobbering. It is NOT protection against
concurrent harness turns - the harness is single-turn by design.

## Keys

Keys are WORKDIR-RELATIVE paths (e.g. `lib/foo.rb`), never absolute: that
makes the persisted session portable - moving the repository to a different
location does not break the cache keys (a session file is saved under its own
`workdir` and restored against it). Files OUTSIDE the workdir fall back to their
canonical path as the key (the same fallback `FileList#display_path` uses for
display). Values are hex SHA-256 digests of the file content as last observed
in-session (a read, or our own write).

The cache API takes CANONICAL (absolute) paths plus the working directory and
derives the relative key itself, so every caller goes through ONE key-derivation
rule (`#key_for`).

## Lifecycle

Owned by the Session (one per session), so the cache is restored with a resumed
session and survives compaction. An entry clears itself when our own write
overwrites it. External changes are cleared by `file.touch` (model-reported) -
only then do write/patch re-hash the on-disk file into the cache without
complaining.
