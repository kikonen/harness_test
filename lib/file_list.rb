# frozen_string_literal: true

require 'digest'

require_relative 'sensitive_files'

# Single source of truth for the allowed file list and ALL access control
# around it (e.g. sensitive-file blocking). Every code path that adds,
# checks, or inspects files (CLI options, the /file command, the dir.allow
# tool, file.read / file.write tools) goes through this class.
#
# Access is granted at two granularities:
#   * individual files (added via add)
#   * directories (added via add_dir) — once a directory is allowed, every
#     file under it (recursively, including subdirectories) is accessible
#     without being individually added. Sensitive files/directories are
#     always blocked, even inside an allowed directory.
#
# All paths are resolved relative to the working directory (@workdir), so
# the harness can operate on a project tree without the user having to
# cd into it first.
#
# Path containment is always decided on CANONICAL paths (see #within?):
# File.expand_path resolves ".." segments and normalizes separators to "/",
# so a check like "is this path under the workdir?" cannot be fooled by
# "../.." escaping or by a mismatch between File::SEPARATOR and the
# separator that File.expand_path actually emits (a real bug on Windows,
# where File::SEPARATOR is "\" but expand_path returns "/").
class FileList
  include Enumerable

  # Class-level guard so callers can check before constructing/adding.
  def self.sensitive?(path)
    SensitiveFiles.sensitive?(path)
  end

  # Compute the SHA-256 hex digest of a file's current contents.
  # Returns nil if the file does not exist.
  def self.sha256(path)
    return nil unless File.file?(path)

    Digest::SHA256.file(path).hexdigest
  end

  attr_reader :workdir

  def initialize(initial = [], workdir: Dir.pwd)
    @workdir = File.expand_path(workdir)
    @files   = []
    @dirs    = []
    initial.each { |f| add(f) }
  end

  # Resolve a path relative to the working directory (absolute paths are
  # returned unchanged). The result is canonical: absolute, ".." segments
  # resolved, and separators normalized to "/".
  def resolve(path)
    File.expand_path(path, @workdir)
  end

  # True if the (canonical) path is the working directory itself or lies
  # under it. Both sides are canonicalized with File.expand_path, so ".."
  # segments are resolved before the comparison — this prevents escaping
  # the workdir via "../.." and works on Windows (where File.expand_path
  # normalizes separators to "/").
  def within_workdir?(path)
    within?(path, @workdir)
  end

  # True if the (canonical) path is the given directory itself or lies
  # under it. Both arguments are canonicalized, so the comparison is
  # separator- and ".."-safe.
  def within?(path, dir)
    path = resolve(path)
    dir  = resolve(dir)
    path == dir || path.start_with?("#{dir}/")
  end

  # Display form of a path: relative to the working directory when the
  # file is inside it (e.g. "lib/cli.rb"), otherwise the full path.
  # Use this for ALL user-facing output so that files in the workdir are
  # shown as short paths and files elsewhere are clearly distinguishable.
  def display_path(path)
    path   = resolve(path)
    prefix = "#{@workdir}/"
    path.start_with?(prefix) ? path.sub(prefix, '') : path
  end

  # Add a file to the list. Returns a symbol describing the outcome:
  #   :added    — file was added
  #   :duplicate — file was already in the list
  #   :blocked  — file is sensitive and can never be added
  #   :is_dir   — the path is a directory; use add_dir (or the dir.allow tool)
  def add(path)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if include?(path)
    return :is_dir    if File.directory?(path)

    @files << path
    :added
  end

  # Add a directory to the allowed list. Once a directory is allowed, every
  # file under it (recursively, including subdirectories) is accessible
  # without being individually added — except sensitive files/directories,
  # which are always blocked. The path must reside under the working
  # directory. Returns a symbol describing the outcome:
  #   :added    — directory was added
  #   :duplicate — directory was already in the list
  #   :blocked  — path is sensitive and can never be allowed
  #   :outside  — path is not under the working directory
  def add_dir(path)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if include?(path)
    return :outside   unless within_workdir?(path)

    @dirs << path
    :added
  end

  # Remove a directory from the allowed list. Returns a symbol describing
  # the outcome:
  #   :removed    — directory was removed
  #   :not_found  — directory was not in the list
  def remove_dir(path)
    path = resolve(path)
    return :not_found unless @dirs.include?(path)

    @dirs.reject! { |d| d == path }
    :removed
  end

  # Remove a file from the list. Returns a symbol describing the outcome:
  #   :removed    — file was removed
  #   :not_found  — file was not in the list
  def remove(path)
    path = resolve(path)
    return :not_found unless @files.include?(path)

    @files.reject! { |f| f == path }
    :removed
  end

  # Rename a file in the list: the old path must be in the list, the new
  # path must not be sensitive. If the new path is already in the list it
  # is replaced by the rename. Returns a symbol describing the outcome:
  #   :renamed   — the list now contains the new path instead of the old one
  #   :not_found — the old path is not in the list
  #   :blocked   — the new path is sensitive and can never be added
  def rename(old_path, new_path)
    old_path = resolve(old_path)
    new_path = resolve(new_path)
    return :not_found unless @files.include?(old_path)
    return :blocked   if sensitive?(new_path)

    @files.reject! { |f| f == old_path || f == new_path }
    @files << new_path
    :renamed
  end

  def sensitive?(path)
    FileList.sensitive?(path)
  end

  # True if the path is an allowed file, or lies under an allowed directory
  # (recursively). Sensitive paths are never considered allowed.
  def include?(path)
    path = resolve(path)
    return false if sensitive?(path)
    return true  if @files.include?(path)

    @dirs.any? { |dir| within?(path, dir) }
  end

  def clear
    @files.clear
    @dirs.clear
  end

  def empty?
    @files.empty? && @dirs.empty?
  end

  def size
    @files.size
  end

  # Allowed directories (copy).
  def dirs
    @dirs.dup
  end

  def to_a
    @files.dup
  end

  def each(&block)
    @files.each(&block)
  end
end
