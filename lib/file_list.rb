# frozen_string_literal: true

require 'digest'

require_relative 'sensitive_files'

# Single source of truth for the allowed file list and ALL access control
# around it (e.g. sensitive-file blocking). Every code path that adds,
# checks, or inspects files (CLI options, the /file command, the file_add
# tool, file_read / file_write tools) goes through this class.
#
# All paths are resolved relative to the working directory (@workdir), so
# the harness can operate on a project tree without the user having to
# cd into it first.
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
    initial.each { |f| add(f) }
  end

  # Resolve a path relative to the working directory (absolute paths are
  # returned unchanged).
  def resolve(path)
    File.expand_path(path, @workdir)
  end

  # Add a file to the list. Returns a symbol describing the outcome:
  #   :added    — file was added
  #   :duplicate — file was already in the list
  #   :blocked  — file is sensitive and can never be added
  def add(path)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if include?(path)

    @files << path
    :added
  end

  def sensitive?(path)
    FileList.sensitive?(path)
  end

  def include?(path)
    @files.include?(resolve(path))
  end

  def clear
    @files.clear
  end

  def empty?
    @files.empty?
  end

  def size
    @files.size
  end

  def to_a
    @files.dup
  end

  def each(&block)
    @files.each(&block)
  end
end
