# File access permissions: the FileList model

Design of `lib/file_list.rb`: how a path becomes readable / writable /
deletable, at what granularity, and which invariants the checks enforce.

Adjacent topics live in their own docs and are not repeated here:
- the sensitive-path guard, scratch/skills/sandbox zones, protected_dirs and posture coverage -> `doc/sensitive_paths_design.md`
- the standing grant on the working directory -> `doc/standing_grant_design.md`
- consent postures for shell commands -> `doc/consent_postures_design.md`

## Modes and granularities

Access is tracked separately for three modes - `:r` read, `:w` write, `:d` delete -
each at three granularities:

- **files** - individual file grants (exact canonical path match).
- **dirs** - directory grants, RECURSIVE: every file under the directory.
- **flat_dirs** - non-recursive directory grants: the dir itself plus its direct
  children only, NOT deeper nesting.

A path is readable/writable/deletable when any of its ancestor directories (up to
and including the working directory) has a grant for that mode, or when the exact
file has a grant. Directory grants are therefore naturally recursive, which is what
listing/searching/editing under a subtree needs.

## Mode rules

- reading a file - a read **or write** grant on the file or an ancestor dir (a write
  grant implies read access to the same path, because writing a file requires reading
  it back).
- listing/searching - read access covering the directory listed.
- writing/patching - a write grant on the file or an ancestor dir. A read grant never
  implies write.
- creating a directory - a write grant on the parent, or on the target itself. The
  grant dialog offers the target directory itself first, so granting does not make the
  parent's existing siblings writeable.
- deleting - a DELETE grant on the affected path (or the parent dir for a directory
  delete). DELETE is its own independent mode: neither read nor write implies delete,
  and delete implies neither. It is granted, persisted, and displayed with the same
  options as read/write.

## Resolution and containment

All paths are resolved relative to the working directory (`@workdir`). Path
containment is decided on canonical paths (`File.expand_path`), so `..` segments and
separator mismatches are handled correctly. `relative_path` returns the
workdir-relative form or nil when the path is outside (the workdir itself included -
it has no relative form); that nil is what makes a whole-tree rule cover the workdir.

`grant_access` renders the consent dialog through the generic `UI::Dialog` with a
widest-first scope ladder (project > whole directory > this file), so the user reads a
scope ladder rather than decoding "dir only" vs "recursive". An option is dropped when
it would do exactly what a wider one already does. An outside-the-workdir path carries
an explicit sandbox-escape warning note. A denial may carry a one-line reason, returned
to the caller so it can be forwarded to the model.

## Grant lifecycle

`revoke_grants` is called after a successful delete: a grant on a path that has just
been removed is stale, and `grant_access` returns `:granted` without a dialog for an
already-granted path, so a lingering grant would skip fresh consent if the same path is
later re-created. Only the exact path is revoked; an ancestor recursive grant stays
(the user granted that parent and it still covers everything else under it).
