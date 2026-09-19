# frozen_string_literal: true

require_relative 'sensitive_files'

# Single source of truth for the allowed file list and ALL access control
# around it (e.g. sensitive-file blocking). Every code path that adds,
# checks, or inspects files (CLI options, the /file command, the file_add
# tool, file_read / file_write tools) goes through this class.
class FileList
  include Enumerable

  # Class-level guard so callers can check before constructing/adding.
  def self.sensitive?(path)
    SensitiveFiles.sensitive?(path)
  end

  def initialize(initial = [])
    @files = []
    initial.each { |f| add(f) }
  end

  # Add a file to the list. Returns a symbol describing the outcome:
  #   :added    — file was added
  #   :duplicate — file was already in the list
  #   :blocked  — file is sensitive and can never be added
  def add(path)
    return :blocked   if sensitive?(path)
    return :duplicate if include?(path)

    @files << path
    :added
  end

  def sensitive?(path)
    FileList.sensitive?(path)
  end

  def include?(path)
    @files.include?(path)
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
