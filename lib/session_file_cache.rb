# frozen_string_literal: true

# issue #170: per-session digest cache for files read in this session.
#
# Replaces the model-facing SHA protocol (the model used to carry a
# sha256 parameter around between file.read and file.write / file.patch):
# the digests are now harness-side state, kept in ONE place.
#
# Purpose: detect a conflict with EXTERNAL changes made after the model
# read a file (user edit, another tool, generated code), so a stale
# write/patch fails with a clear error instead of silently clobbering.
# It is NOT protection against concurrent harness turns - the harness is
# single-turn by design.
#
# Keys are canonical absolute paths; values are hex SHA-256 digests of
# the file content as last observed in-session (read, or our own write).
#
# Lifecycle: owned by the Session (one per session), so the cache is
# restored with a resumed session and survives compaction. An entry
# clears itself when our own write overwrites it; external changes are
# cleared by file.touch (model-reported) - only then do write/patch
# re-hash the on-disk file into the cache without complaining.

class SessionFileCache
  def initialize
    @digests = {}
  end

  # Record the digest of a file (canonical path, hex digest).
  def record(path, digest)
    @digests[path] = digest
    self
  end

  # The recorded digest for a canonical path, or nil when the file has
  # not been read in this session (nothing to compare against).
  def known?(path)
    @digests.key?(path)
  end

  def digest(path)
    @digests[path]
  end

  # Drop an entry (external change via file.touch, or file moved away
  # via file.rename). Missing entries are a no-op.
  def clear(path)
    @digests.delete(path)
    self
  end

  # Register a file rename (move): the digest travels with the file, so
  # the entry is re-keyed under the new path. A missing old path means
  # the file had no cached entry - nothing to move.
  def rename(old_path, new_path)
    return self unless known?(old_path)

    @digests[new_path] = @digests.delete(old_path)
    self
  end

  def clear_all
    @digests.clear
    self
  end

  def empty?
    @digests.empty?
  end

  # Serialize to a plain hash (JSON-safe).
  def to_h
    @digests.dup
  end

  # Restore from a plain hash (as produced by Session#to_h after a JSON
  # round trip, so string keys). Entries without a usable digest are
  # skipped. Returns self for chaining.
  def restore(data)
    clear_all
    data.each do |path, digest|
      next unless path.is_a?(String) && digest.is_a?(String) && !digest.empty?

      @digests[path] = digest
    end
    self
  end
end
