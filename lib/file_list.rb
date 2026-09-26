# frozen_string_literal: true

require 'digest'

require_relative 'sensitive_files'

# Single source of truth for file access permissions.
#
# Access is granted at three granularities:
#   * files  — individual file grants (exact path match)
#   * dirs   — non-recursive directory grants (only direct children)
#   * trees  — recursive directory grants (all files under the directory)
#
# Sensitive files/directories are always blocked, regardless of grants.
#
# All paths are resolved relative to the working directory (@workdir).
# Path containment is decided on canonical paths (File.expand_path),
# so ".." segments and separator mismatches are handled correctly.
class FileList
  include Enumerable

  def self.sensitive?(path)
    SensitiveFiles.sensitive?(path)
  end

  def self.sha256(path)
    return nil unless File.file?(path)

    Digest::SHA256.file(path).hexdigest
  end

  attr_reader :workdir

  def initialize(initial = [], workdir: Dir.pwd)
    @workdir = File.expand_path(workdir)
    @files   = []
    @dirs    = []
    @trees   = []
    initial.each { |f| add_file(f) }
  end

  # Resolve a path relative to the working directory.
  def resolve(path)
    File.expand_path(path, @workdir)
  end

  # True if the (canonical) path is the given directory itself or lies under it.
  def within?(path, dir)
    path = resolve(path)
    dir  = resolve(dir)
    path == dir || path.start_with?("#{dir}/")
  end

  # True if the (canonical) path is the working directory itself or lies under it.
  def within_workdir?(path)
    within?(path, @workdir)
  end

  # Display form of a path: relative to the working directory when possible.
  def display_path(path)
    path   = resolve(path)
    prefix = "#{@workdir}/"
    path.start_with?(prefix) ? path.sub(prefix, '') : path
  end

  def sensitive?(path)
    FileList.sensitive?(path)
  end

  # True if the path is accessible (any tier). Sensitive paths are never accessible.
  def include?(path)
    path = resolve(path)
    return false if sensitive?(path)
    return true  if @files.include?(path)

    parent = File.dirname(path)
    return true if @dirs.include?(parent)

    @trees.any? { |t| within?(path, t) }
  end

  # Grant access to a single file.
  def add_file(path)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if @files.include?(path)

    @files << path
    :added
  end

  # Alias for add_file (backward compatibility).
  def add(path)
    add_file(path)
  end

  # Grant access to a directory (non-recursive: only direct children).
  def add_dir(path)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if @dirs.include?(path)
    return :outside   unless within_workdir?(path)

    @dirs << path
    :added
  end

  # Grant access to a directory tree (recursive: all files under it).
  def add_tree(path)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if @trees.include?(path)
    return :outside   unless within_workdir?(path)

    @trees << path
    :added
  end

  # Prompt the user to grant access to a path.
  # Returns :granted, :denied, or :blocked.
  def grant_access(path, context = nil)
    path  = resolve(path)
    shown = display_path(path)

    return :granted if include?(path)
    return :blocked if sensitive?(path)

    parent            = File.dirname(path)
    parent_in_workdir = within_workdir?(parent)

    puts
    puts "  [access] ⚠  Access requested: #{shown}"
    puts "             1) Allow this file only"
    if parent_in_workdir
      parent_shown = display_path(parent)
      puts "             2) Allow directory: #{parent_shown}/ (direct files only)"
      puts "             3) Allow directory tree: #{parent_shown}/ (recursive)"
      print  "             Choice (1/2/3): "
    else
      print  "             Allow? (y/n): "
    end
    $stdout.flush

    answer = $stdin.gets&.chomp&.strip

    if parent_in_workdir
      case answer
      when '1'
        add_file(path)
        puts "  [access] ✓ #{shown}"
        :granted
      when '2'
        add_dir(parent)
        puts "  [access] ✓ #{display_path(parent)}/"
        :granted
      when '3'
        add_tree(parent)
        puts "  [access] ✓ #{display_path(parent)}/ (recursive)"
        :granted
      else
        puts "  [access] ✗ denied"
        :denied
      end
    else
      if answer == 'y' || answer == 'yes'
        add_file(path)
        puts "  [access] ✓ #{shown}"
        :granted
      else
        puts "  [access] ✗ denied"
        :denied
      end
    end
  end

  # Remove a file from the list.
  def remove(path)
    path = resolve(path)
    @files.delete(path) ? :removed : :not_found
  end

  # Rename a file in the list.
  def rename(old_path, new_path)
    old_path = resolve(old_path)
    new_path = resolve(new_path)
    return :not_found unless @files.include?(old_path)
    return :blocked   if sensitive?(new_path)

    @files.reject! { |f| f == old_path || f == new_path }
    @files << new_path
    :renamed
  end

  def clear
    @files.clear
    @dirs.clear
    @trees.clear
  end

  def empty?
    @files.empty? && @dirs.empty? && @trees.empty?
  end

  def size
    @files.size
  end

  def files
    @files.dup
  end

  def dirs
    @dirs.dup
  end

  def trees
    @trees.dup
  end

  def to_a
    @files.dup
  end

  def each(&block)
    @files.each(&block)
  end
end
