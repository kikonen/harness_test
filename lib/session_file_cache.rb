# frozen_string_literal: true

# Per-session digest cache: detects a write over a file an external edit
# changed after the model read it; keys and lifecycle:
# doc/session_file_cache_design.md

class SessionFileCache
  def initialize
    @digests = {}
  end

  # Record the digest of a file. `path` is the canonical (absolute) path,
  # `workdir` the working directory the key is derived relative to, and
  # `digest` the hex SHA-256.
  def record(path, digest, workdir: nil)
    @digests[key_for(path, workdir)] = digest
    self
  end

  # The recorded digest for a file (canonical path + workdir), or nil when
  # it has not been read in this session (nothing to compare against).
  def digest(path, workdir: nil)
    @digests[key_for(path, workdir)]
  end

  # True when a file has an entry (see #digest).
  def known?(path, workdir: nil)
    @digests.key?(key_for(path, workdir))
  end

  # Drop an entry (external change via file.touch, or file moved away via
  # file.rename / deleted). Missing entries are a no-op.
  def clear(path, workdir: nil)
    @digests.delete(key_for(path, workdir))
    self
  end

  # Register a file rename (move): the digest travels with the file, so
  # the entry is re-keyed under the new path. A missing old path means
  # the file had no cached entry - nothing to move.
  def rename(old_path, new_path, workdir: nil)
    old_key = key_for(old_path, workdir)
    return self unless known?(old_path, workdir: workdir)

    @digests[key_for(new_path, workdir)] = @digests.delete(old_key)
    self
  end

  def clear_all
    @digests.clear
    self
  end

  def empty?
    @digests.empty?
  end

  # Serialize to a plain hash (JSON-safe). Keys are relative paths.
  def to_h
    @digests.dup
  end

  # Restore from a plain hash (as produced by Session#to_h after a JSON
  # round trip, so string keys). Entries without a usable digest are
  # skipped and kept verbatim - no path translation: relative keys are
  # location-independent by design. Returns self for chaining.
  def restore(data)
    clear_all
    data.each do |path, digest|
      next unless path.is_a?(String) && digest.is_a?(String) && !digest.empty?

      @digests[path] = digest
    end
    self
  end

  private

  # The single key-derivation rule: workdir-relative when the path lies
  # inside the workdir (same logic as FileList#display_path), canonical
  # path otherwise. Without a workdir (specs) the canonical path is used
  # directly - callers pass absolute paths in then, so lookups stay
  # consistent within a process.
  def key_for(path, workdir)
    return path if workdir.nil? || workdir.to_s.empty?

    prefix = "#{workdir}/"
    path.start_with?(prefix) ? path.sub(prefix, '') : path
  end
end
