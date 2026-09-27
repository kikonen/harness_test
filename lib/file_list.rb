# frozen_string_literal: true

require 'digest'

require_relative 'sensitive_files'
require_relative 'dialog'

# Single source of truth for file access permissions.
#
# Access is tracked SEPARATELY for reads and writes, at two granularities:
#   * files  - individual file grants (exact path match)
#   * dirs   - directory grants (RECURSIVE: every file under the directory)
#
#   * flat_dirs - non-recursive directory grants (the dir itself + direct
#     children only, NOT deeper nesting)
#
# A path is readable/writable when any of its ancestor directories (up to
# and including the working directory) has a grant for that mode, or when
# the exact file has a grant. This makes directory grants naturally
# recursive, which is what listing/searching/editing under a subtree needs.
#
# Permission rules:
#   * reading a file        -> read grant on the file or an ancestor dir
#   * listing/searching     -> read grant covering the directory listed
#   * writing/patching      -> write grant on the file or an ancestor dir
#   * creating a directory  -> write grant on the PARENT directory, or on
#                              the target directory itself
#   * deleting/renaming     -> write grant on the affected path(s)
#
# For dir.create the grant dialog offers the TARGET DIRECTORY ITSELF as the
# first option (issue #54), so granting does not make existing siblings of
# the parent writeable.
#
# A write grant implies read access to the same path (writing a file
# requires reading it back), but a read grant never implies write.
#
# Sensitive files/directories are always blocked, regardless of grants.
#
# All paths are resolved relative to the working directory (@workdir).
# Path containment is decided on canonical paths (File.expand_path),
# so ".." segments and separator mismatches are handled correctly.
class FileList
  include Enumerable

  # Permission modes.
  MODES = %i[r w rw].freeze

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
    # grants[mode] -> { files: [...], dirs: [...] } of canonical paths.
    # "dirs" grants are recursive (cover every file under the directory).
    # "flat_dirs" grants are non-recursive (dir itself + direct children).
    @grants = { r: { files: [], dirs: [], flat_dirs: [] },
                w: { files: [], dirs: [], flat_dirs: [] } }
    initial.each { |f| add_file(f, :rw) }
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
    return '.' if path == @workdir
    prefix = "#{@workdir}/"
    path.start_with?(prefix) ? path.sub(prefix, '') : path
  end

  def sensitive?(path)
    FileList.sensitive?(path)
  end

  # -- permission checks ----------------------------------------------------

  # True if the path is readable: a read OR write grant on the file itself
  # or on any ancestor directory (recursive). Writing a file requires being
  # able to read it back, so a write grant implies read access to the same
  # path - but a read grant never implies write. Sensitive paths are never
  # accessible.
  def readable?(path)
    path = resolve(path)
    return false if sensitive?(path)
    return true  if @grants[:r][:files].include?(path) ||
                    @grants[:w][:files].include?(path)
    return true  if @grants[:r][:flat_dirs].include?(path) ||
                    @grants[:w][:flat_dirs].include?(path)
    return true  if flat_dir_covers?(@grants[:r][:flat_dirs], path) ||
                    flat_dir_covers?(@grants[:w][:flat_dirs], path)

    ancestor_granted?(@grants[:r][:dirs], path) ||
      ancestor_granted?(@grants[:w][:dirs], path)
  end

  # Backward-compatible alias: a path is "included" when it is readable.
  def include?(path)
    readable?(path)
  end

  # True if the path is writable: a write grant on the file itself or on any
  # ancestor directory (recursive). Sensitive paths are never accessible.
  # A read grant does NOT imply write access.
  def writable?(path)
    path = resolve(path)
    return false if sensitive?(path)
    return true  if @grants[:w][:files].include?(path)
    return true  if @grants[:w][:flat_dirs].include?(path)
    return true  if flat_dir_covers?(@grants[:w][:flat_dirs], path)

    ancestor_granted?(@grants[:w][:dirs], path)
  end

  # True if a directory can be listed: read access to the directory itself.
  def can_list_dir?(dir)
    readable?(dir)
  end

  # Summary of all grants, grouped by effective access. Each section is a
  # list of canonical paths; "both" (granted for read AND write) is listed
  # first and excluded from the read-only / write-only sections, so no path
  # appears twice. Used by the CLI display, the user prompt, and /session.
  def accessible_paths
    r_files = @grants[:r][:files].uniq
    w_files = @grants[:w][:files].uniq
    r_dirs  = @grants[:r][:dirs].uniq
    w_dirs  = @grants[:w][:dirs].uniq
    r_flat  = @grants[:r][:flat_dirs].uniq
    w_flat  = @grants[:w][:flat_dirs].uniq

    files_both  = (r_files & w_files).sort
    dirs_both   = (r_dirs & w_dirs).sort
    flat_both   = (r_flat & w_flat).sort
    files_read  = (r_files - w_files).sort
    dirs_read   = (r_dirs - w_dirs).sort
    flat_read   = (r_flat - w_flat).sort
    files_write = (w_files - r_files).sort
    dirs_write  = (w_dirs - r_dirs).sort
    flat_write  = (w_flat - r_flat).sort

    {
      both:  { files: files_both,  dirs: dirs_both,   flat_dirs: flat_both },
      read:  { files: files_read,  dirs: dirs_read,   flat_dirs: flat_read },
      write: { files: files_write, dirs: dirs_write,  flat_dirs: flat_write }
    }
  end

  # -- grants ---------------------------------------------------------------

  # Grant access to a single file. mode: :r, :w, or :rw (default).
  def add_file(path, mode = :rw)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if granted?(mode, :files, path)

    grant(mode, :files, path)
    :added
  end

  # Alias for add_file (backward compatibility).
  def add(path, mode = :rw)
    add_file(path, mode)
  end

  # Grant access to a directory (recursive: every file under it).
  def add_dir(path, mode = :rw)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if granted?(mode, :dirs, path)

    grant(mode, :dirs, path)
    :added
  end

  # Grant access to a directory (non-recursive: the dir itself + direct
  # children only, NOT deeper nesting).
  def add_flat_dir(path, mode = :rw)
    path = resolve(path)
    return :blocked   if sensitive?(path)
    return :duplicate if granted?(mode, :flat_dirs, path)

    grant(mode, :flat_dirs, path)
    :added
  end

  # Alias for add_dir (recursive directory grant; kept for clarity).
  def add_tree(path, mode = :rw)
    add_dir(path, mode)
  end

  # Prompt the user to grant access to a path.
  # mode: :r (read), :w (write), or :rw (read + write; default).
  # purpose: optional string explaining WHY access is needed (e.g. "to create directory 'somedir'").
  # Returns :granted, :blocked, or on denial a hash
  # { status: :denied, note: <user's note or nil> } so the caller can
  # forward the user's feedback to the model (see Tool#denial_error).
  #
  # The prompt is rendered through the generic Dialog (numbered options +
  # standard cancel), so the user has a consistent interaction pattern
  # regardless of path location.
  def grant_access(path, mode = :rw, purpose: nil)
    path  = resolve(path)
    shown = display_path(path)

    return :granted if readable?(path) && (mode == :r || writable?(path))
    return :blocked if sensitive?(path)

    verb = mode == :r ? 'read access' : 'write access'

    # Decide the branch on PATH LOCATION, not existence: a new file that does
    # not exist yet must still be treated as inside-workdir. Existence is only
    # used to pick dir-style vs file-style prompt options.
    is_dir      = File.directory?(path)
    inside      = within_workdir?(path)
    # Treat an inside-workdir path as a "file" prompt unless it is a real
    # directory (a non-existent target defaults to the file-style prompt).
    dir_prompt  = inside && is_dir
    file_prompt = inside && !is_dir

    parent       = File.dirname(path)
    parent_shown = display_path(parent)

    options = if dir_prompt || is_dir
      # Directory: offer flat or recursive.
      [
        Dialog::Option.new(title: 'Allow this directory only', value: :flat),
        Dialog::Option.new(
          title: 'Allow this directory and subdirs (recursive)',
          value: :recursive,
          description: 'covers every file under the directory'
        )
      ]
    elsif file_prompt && mode == :w
      # A not-yet-existing directory (e.g. dir.create): prefer a grant on
      # the target itself so existing siblings of the parent are NOT made
      # writeable (issue #54).
      [
        Dialog::Option.new(
          title: "Allow this directory only: #{shown}",
          value: :target,
          description: 'grant covers just this new directory'
        ),
        Dialog::Option.new(
          title: "Allow parent directory: #{parent_shown}/ (dir only)",
          value: :parent_flat,
          description: 'the parent itself + direct children - makes ALL of them writeable'
        ),
        Dialog::Option.new(
          title: "Allow parent directory: #{parent_shown}/ (recursive)",
          value: :parent_recursive,
          description: 'every file under the parent'
        )
      ]
    elsif file_prompt
      # File within workdir: offer file-only or parent-dir (flat/recursive).
      [
        Dialog::Option.new(title: 'Allow this file only', value: :file),
        Dialog::Option.new(
          title: "Allow directory: #{parent_shown}/ (dir only)",
          value: :parent_flat,
          description: 'the directory itself + direct children only'
        ),
        Dialog::Option.new(
          title: "Allow directory: #{parent_shown}/ (recursive)",
          value: :parent_recursive,
          description: 'every file under the directory'
        )
      ]
    else
      # Outside workdir or special path.
      [
        Dialog::Option.new(
          title: 'Allow',
          value: :flat,
          description: is_dir ? 'this directory only (not subdirs)' : nil
        )
      ]
    end

    note = purpose
    unless inside
      warn_line = 'WARNING: this path is OUTSIDE the working directory - ' \
                  'granting access may be a sandbox escape.'
      note  = [note, warn_line].compact.join("\n")
    end

    choice = Dialog.new(
      title: "Access requested (#{verb}): #{shown}",
      options: options,
      note: note
    ).show

    # The user may attach a short note to any choice ("<number> <note>");
    # the dialog then returns [value, note]. Unwrap it - the note is just
    # extra context, the selection itself drives the grant.
    note_text = choice.is_a?(Array) ? choice[1] : nil
    choice    = choice[0] if choice.is_a?(Array)
    case choice
    when :target
      add_file(path, mode)
      puts "  [access] ✓ #{shown}/ (dir itself only, #{mode_label(mode)})"
      :granted
    when :file
      add_file(path, mode)
      puts "  [access] ✓ #{shown} (#{mode_label(mode)})"
      :granted
    when :flat
      if is_dir
        add_flat_dir(path, mode)
        puts "  [access] ✓ #{shown}/ (dir only, #{mode_label(mode)})"
      else
        add_file(path, mode)
        puts "  [access] ✓ #{shown} (#{mode_label(mode)})"
      end
      :granted
    when :recursive
      add_dir(path, mode)
      puts "  [access] ✓ #{shown}/ (recursive, #{mode_label(mode)})"
      :granted
    when :parent_flat
      add_flat_dir(parent, mode)
      puts "  [access] ✓ #{parent_shown}/ (dir only, #{mode_label(mode)})"
      :granted
    when :parent_recursive
      add_dir(parent, mode)
      puts "  [access] ✓ #{parent_shown}/ (recursive, #{mode_label(mode)})"
      :granted
    else
      if note_text
        puts "  [access] ✗ denied (user's note: \"#{note_text}\")"
      else
        puts "  [access] ✗ denied"
      end
      { status: :denied, note: note_text }
    end
  end

  # Remove a file grant from the list.
  def remove(path, mode = :rw)
    path = resolve(path)
    removed = false
    grant(mode, :files) { |list| removed ||= list.delete(path) }
    removed ? :removed : :not_found
  end

  # Rename a file grant in the list (applies to both read and write grants).
  def rename(old_path, new_path)
    old_path = resolve(old_path)
    new_path = resolve(new_path)
    return :not_found unless (@grants[:r][:files] + @grants[:w][:files]).include?(old_path)
    return :blocked   if sensitive?(new_path)

    [:r, :w].each do |mode|
      list = @grants[mode][:files]
      had_grant = list.include?(old_path)
      list.reject! { |f| f == old_path || f == new_path }
      list << new_path if had_grant
    end
    :renamed
  end

  def clear
    [:r, :w].each do |mode|
      @grants[mode][:files].clear
      @grants[mode][:dirs].clear
      @grants[mode][:flat_dirs].clear
    end
  end

  def empty?
    [:r, :w].all? do |mode|
      @grants[mode][:files].empty? && @grants[mode][:dirs].empty? &&
        @grants[mode][:flat_dirs].empty?
    end
  end

  def size
    (@grants[:r][:files] + @grants[:w][:files]).uniq.size
  end

  # Total number of distinct access grants (files + directories, across
  # both read and write modes).
  def access_grant_count
    (@grants[:r][:files] + @grants[:w][:files] +
     @grants[:r][:dirs] + @grants[:w][:dirs] +
     @grants[:r][:flat_dirs] + @grants[:w][:flat_dirs]).uniq.size
  end

  # Grants for a mode (default :r). mode may be :r, :w, or :rw (union of both).
  def files(mode = :r)
    lists_for(mode, :files)
  end

  def dirs(mode = :r)
    lists_for(mode, :dirs)
  end

  def flat_dirs(mode = :r)
    lists_for(mode, :flat_dirs)
  end

  # Backward-compatible accessor for recursive dir grants.
  def trees(mode = :r)
    dirs(mode)
  end

  def to_a
    files(:rw)
  end

  def each(&block)
    to_a.each(&block)
  end

  # True if the path is a direct child of (or equal to) any directory in the
  # given flat_dirs list. A flat grant covers the dir itself and its direct
  # children, but NOT deeper nesting.
  def flat_dir_covers?(flat_dirs, path)
    return false if flat_dirs.empty?

    parent = File.dirname(path)
    flat_dirs.any? { |d| d == parent }
  end

  private

  # True if the path itself (when it is a granted directory) or any of its
  # ancestor directories is present in the given list of granted directories.
  def ancestor_granted?(granted_dirs, path)
    return true if granted_dirs.include?(path)

    dir = File.dirname(path)
    loop do
      return true if granted_dirs.include?(dir)
      return false if dir == '/'

      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    false
  end

  def mode_label(mode)
    case mode
    when :r then 'read'
    when :w then 'write'
    else 'read+write'
    end
  end

  def granted?(mode, tier, path)
    lists_for(mode, tier).include?(path)
  end

  # Grant a path under the given mode(s) and tier.
  # With a block: applies the block to each affected list (used by #remove).
  def grant(mode, tier, path = nil, &block)
    modes = mode == :rw ? %i[r w] : [mode].flatten
    modes.each do |m|
      next unless %i[r w].include?(m)

      list = @grants[m][tier]
      if block
        yield list
      else
        list << path unless list.include?(path)
      end
    end
  end

  def lists_for(mode, tier)
    case mode
    when :r then @grants[:r][tier].dup
    when :w then @grants[:w][tier].dup
    else (@grants[:r][tier] + @grants[:w][tier]).uniq
    end
  end
end
