# frozen_string_literal: true

require "digest"

require_relative "sensitive_files"
require_relative "ui/dialog"
require_relative "tool"

# Single source of truth for file access permissions. Modes/granularities, the
# permission rules and the consent ladder: doc/file_access_design.md. The sensitive
# guard and posture coverage: doc/sensitive_paths_design.md.
class FileList
  include Enumerable

  # Permission modes.
  MODES = %i[r w d rw].freeze

  # Characters Dir.glob expands (braces, brackets, wildcards). A segment holding
  # one is no longer a directory name, which is what glob_base_dir splits on.
  GLOB_METACHARS = /[\[\]*?{}]/
  # Both separators: an expanded path uses "/", a pattern may carry "\".
  PATH_SEPARATORS = %r{[/\\]}

  # The YOLO posture reader (Harness#yolo?). Read on EVERY check so a /yolo at the
  # idle prompt or a mid-turn flip applies to the next tool call, and switching it
  # off removes coverage at once. nil = no posture.
  attr_accessor :posture

  # The logger posture coverage reports itself to (an auto-approval must leave a
  # trace, as YOLO's shell runs do). Set by Harness#initialize after its logger exists.
  attr_accessor :audit_logger

  # One audit line per MODE per session, not per access: file.list/file.search call
  # readable? on every candidate, so a covered workdir would print hundreds of duplicates.
  attr_reader :posture_announced

  def self.sha256(path)
    return nil unless File.file?(path)

    Digest::SHA256.file(path).hexdigest
  end

  attr_reader :workdir

  def initialize(initial = [], workdir: Dir.pwd, protected_dirs: nil)
    @workdir = File.expand_path(workdir)
    # grants[mode] -> { files: [...], dirs: [...], flat_dirs: [...] } of canonical paths.
    # "dirs" grants are recursive, "flat_dirs" grants cover the dir + direct children only.
    @grants = { r: { files: [], dirs: [], flat_dirs: [] },
                w: { files: [], dirs: [], flat_dirs: [] },
                d: { files: [], dirs: [], flat_dirs: [] } }
    @posture = nil
    @posture_announced = { r: false, w: false, d: false }
    # Workdir-relative dirs the posture never auto-covers: a human grant may still cover
    # them, but an auto-approval must not quietly remove the veto kept there. nil = the
    # default (the owner's space, local/); the config 'protected_dirs:' key supplies the list.
    @protected_dirs = protected_dirs.nil? ? [SensitiveFiles::OWNER_DIR] : protected_dirs
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
    return "." if path == @workdir

    relative_path(path) || path
  end

  # Path relative to the working directory, or nil when it lies outside it
  # (the working directory itself included - it has no relative form).
  def relative_path(path)
    path   = resolve(path)
    return nil if path == @workdir
    prefix = "#{@workdir}/"
    path.start_with?(prefix) ? path[prefix.length..] : nil
  end

  # True when the path lies inside a per-issue scratch zone (tmp/scratch/<n>/ or
  # tmp/keep/<n>/). The test needs the RELATIVE path - tmp/ is where zones live - and
  # relative_path has already resolved any ".." away, so a zone name as an escape route
  # does not match.
  def scratch_zone?(path)
    SensitiveFiles.scratch_zone?(relative_path(path))
  end

  # The single decision point for "blocked whatever the grants": a sensitive NAME,
  # unless inside a scratch zone (a nested .git there is a disposable clone), the
  # project's own skills dir (repo content the owner keeps), or the Ruby sandbox (the
  # model manages that Gemfile with bundle, which already writes it from a shell) -
  # where only a .env* NAME still blocks. doc/sensitive_paths_design.md.
  def sensitive?(path)
    rel = relative_path(path)
    return false if SensitiveFiles.scratch_zone?(rel)
    if SensitiveFiles.skills_zone?(rel) || SensitiveFiles.sandbox_zone?(rel)
      return SensitiveFiles.env_named?(path)
    end

    SensitiveFiles.sensitive?(path)
  end

  # -- permission checks ----------------------------------------------------

  # True if readable: a read OR write grant on the file or any ancestor directory
  # (recursive). A write grant implies read (writing requires reading it back), but a
  # read grant never implies write. Sensitive paths are never accessible.
  def readable?(path)
    path = resolve(path)
    return false if sensitive?(path)
    return true  if posture_covers?(path, :r)

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

  # True if writable: a write grant on the file or any ancestor directory. A read
  # grant does NOT imply write. Sensitive paths are never accessible.
  def writable?(path)
    path = resolve(path)
    return false if sensitive?(path)
    return true  if posture_covers?(path, :w)

    return true  if @grants[:w][:files].include?(path)
    return true  if @grants[:w][:flat_dirs].include?(path)
    return true  if flat_dir_covers?(@grants[:w][:flat_dirs], path)

    ancestor_granted?(@grants[:w][:dirs], path)
  end

  # True if deletable: a DELETE grant on the file or any ancestor directory. A read or
  # write grant does NOT imply delete - delete is its own mode. Sensitive paths never.
  def deletable?(path)
    path = resolve(path)
    return false if sensitive?(path)
    return true  if posture_covers?(path, :d)

    return true  if @grants[:d][:files].include?(path)
    return true  if @grants[:d][:flat_dirs].include?(path)
    return true  if flat_dir_covers?(@grants[:d][:flat_dirs], path)

    ancestor_granted?(@grants[:d][:dirs], path)
  end

  # True if a directory can be listed: read access to the directory itself.
  def can_list_dir?(dir)
    readable?(dir)
  end

  # The directory a glob pattern points at - what listing it needs READ on. Derived from
  # the pattern's SEGMENTS, because only a plain wildcard is strippable from a string: a
  # brace/bracket glob ('{lib,spec}/*') has no leading '*', so cutting at the first
  # metacharacter asks for a non-existent directory. A pattern with no metacharacter is an
  # ordinary path: a directory is its own base, a file needs its parent.
  def glob_base_dir(pattern)
    expanded = resolve(pattern.to_s)
    segments = expanded.split(PATH_SEPARATORS)
    literal  = segments.take_while { |segment| !GLOB_METACHARS.match?(segment) }

    return expanded if literal.size == segments.size && File.directory?(expanded)
    return File.dirname(expanded) if literal.size == segments.size

    resolve(literal.join("/"))
  end

  # Summary of all grants grouped by effective access. Each section is a list of canonical
  # paths; "both" (read AND write) is listed first and excluded from read-only/write-only,
  # so no path appears twice there. Delete is an independent section (a delete-granted path
  # may also appear under read/write). Used by the CLI display, the prompt, and /session.
  def accessible_paths
    r_files = @grants[:r][:files].uniq
    w_files = @grants[:w][:files].uniq
    r_dirs  = @grants[:r][:dirs].uniq
    w_dirs  = @grants[:w][:dirs].uniq
    r_flat  = @grants[:r][:flat_dirs].uniq
    w_flat  = @grants[:w][:flat_dirs].uniq
    d_files = @grants[:d][:files].uniq
    d_dirs  = @grants[:d][:dirs].uniq
    d_flat  = @grants[:d][:flat_dirs].uniq

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
      write: { files: files_write, dirs: dirs_write,  flat_dirs: flat_write },
      delete: {
        files: d_files.sort,
        dirs: d_dirs.sort,
        flat_dirs: d_flat.sort
      }
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

  # Grant access to a directory (non-recursive: the dir + direct children only).
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
  # mode: :r, :w, :d, or :rw (default). purpose: optional string explaining WHY.
  # Returns :granted, :blocked, or on denial { status: :denied, note: <user note or nil> }
  # so the caller can forward the user's feedback to the model (Tool#denial_error).
  # Rendered through the generic Dialog, so the interaction pattern is consistent.
  def grant_access(path, mode = :rw, purpose: nil)
    path  = resolve(path)
    shown = display_path(path)

    return :granted if mode == :r && readable?(path)
    return :granted if mode == :w && writable?(path)
    return :granted if mode == :d && deletable?(path)
    return :blocked if sensitive?(path)

    verb = case mode
           when :r then "read access"
           when :d then "delete access"
           else "write access"
           end

    # inside/outside is decided on PATH LOCATION (a not-yet-existing path is still inside
    # if it resolves under the workdir); is_dir picks dir- vs file-style options; a path
    # that does not exist yet AND is being written takes the create (target-first) ladder.
    is_dir = File.directory?(path)
    inside = within_workdir?(path)

    parent       = File.dirname(path)
    parent_shown = display_path(parent)

    # Plain-language, WIDEST-FIRST choices: the user reads a scope ladder (project > whole
    # directory > just this) instead of decoding "(dir only)" vs "(recursive)". An option is
    # dropped when it would do exactly what a wider one already does. The project-wide option
    # is offered only when the workdir itself is not sensitive (a workdir under .git/.harness
    # has no grantable project-wide scope).
    project = !sensitive?(@workdir) && UI::Dialog::Option.new(
      title: "Allow every file in the project",
      value: :workdir,
      description: "one grant covering the whole working directory - sensitive " \
                   "paths (.git/.harness/.env*) still stay blocked"
    )
    whole_dir = lambda do |dir_path, dir_shown|
      UI::Dialog::Option.new(
        title: "Allow everything in #{dir_shown}/ and below (whole tree)",
        value: :recursive,
        description: "every file under #{dir_shown}/, at any depth"
      ) if dir_path != @workdir
    end
    direct_only = lambda do |dir_path, dir_shown|
      label = dir_path == @workdir ? "the project" : "#{dir_shown}/"
      UI::Dialog::Option.new(
        title: "Allow only the files directly in #{label} (not subfolders)",
        value: :flat
      )
    end

    options = if inside && is_dir
      # A directory inside the workdir.
      ladder = []
      ladder << project if project
      whole = whole_dir.call(path, shown)
      ladder << whole if whole
      ladder << direct_only.call(path, shown)
      ladder
    elsif inside && !File.exist?(path) && mode == :w
      # A path being CREATED: the new path is offered FIRST (narrow-first), so granting it
      # does NOT make the parent's existing siblings writeable. A parent that IS the project
      # reads as "the project", not "./".
      parent_label = parent == @workdir ? "the project" : "#{parent_shown}/"
      [
        UI::Dialog::Option.new(
          title: "Allow only this new path: #{shown}",
          value: :target,
          description: "covers only this new file or directory - existing siblings of " \
                       "#{parent_label} stay ungranted"
        ),
        UI::Dialog::Option.new(
          title: "Allow every file under #{parent_label} (whole directory)",
          value: :parent_recursive
        ),
        UI::Dialog::Option.new(
          title: "Allow only the files directly in #{parent_label} (not subfolders)",
          value: :parent_flat
        )
      ]
    elsif inside
      # A file inside the workdir: project > parent (whole dir) > this file. The parent option
      # is dropped when the parent IS the project root (it would equal the project option).
      file_opts = []
      file_opts << project if project
      whole = whole_dir.call(parent, parent_shown)
      file_opts << whole if whole
      file_opts << UI::Dialog::Option.new(title: "Allow only this file", value: :file)
      file_opts
    else
      # Outside the workdir: the project-wide ladder does not apply. A directory keeps its
      # two grant levels (whole tree / direct children only); a single outside file is just
      # "Allow". The OUTSIDE warning below is what the user weighs here.
      if is_dir
        [
          UI::Dialog::Option.new(
            title: "Allow everything in #{shown}/ and below (whole tree)",
            value: :recursive
          ),
          UI::Dialog::Option.new(
            title: "Allow only the files directly in #{shown}/ (not subfolders)",
            value: :flat
          )
        ]
      else
        [UI::Dialog::Option.new(title: "Allow", value: :flat)]
      end
    end

    # Each note line states its KIND: the purpose is context; the outside-the-workdir warning
    # is the line the user must weigh before granting - so the console can tell them apart.
    notes = [purpose].compact
    unless inside
      notes << UI::Dialog::Note.new(
        "WARNING: this path is OUTSIDE the working directory - " \
        "granting access may be a sandbox escape.",
        kind: "warn")
    end

    choice = UI::Dialog.new(
      title: "Access requested (#{verb}): #{shown}",
      options:,
      note: notes,
    ).show(ui: nil)

    # A user may attach a one-line reason to the CANCEL choice ("<cancel number> <reason>"),
    # returned as [CANCEL_VALUE, reason]. Unwrap it: the reason is feedback on the denial, the
    # selection drives the grant.
    note_text = choice.is_a?(Array) ? choice[1] : nil
    choice    = choice[0] if choice.is_a?(Array)
    # Feedback line. grant_access runs on the task thread, so this goes through the task's event
    # queue, never a bare puts onto $stdout from the wrong thread. "access" is the bracket label.
    report = lambda do |verdict, message|
      Tool.push_status(label: "access", verdict:, message:)
    end
    case choice
    when :target
      add_file(path, mode)
      report.call(:ok, "#{shown}/ (dir itself only, #{mode_label(mode)})")
      :granted
    when :workdir
      # The project-wide choice. Same tier as #seed_standing_grant uses, so a grant chosen
      # here behaves exactly like the config default.
      add_dir(@workdir, mode)
      report.call(:ok, "the whole project (every file under #{@workdir}, #{mode_label(mode)})")
      :granted
    when :file
      add_file(path, mode)
      report.call(:ok, "#{shown} (#{mode_label(mode)})")
      :granted
    when :flat
      if is_dir
        add_flat_dir(path, mode)
        report.call(:ok, "#{shown}/ direct children only (#{mode_label(mode)})")
      else
        add_file(path, mode)
        report.call(:ok, "#{shown} (#{mode_label(mode)})")
      end
      :granted
    when :recursive
      add_dir(path, mode)
      report.call(:ok, "#{shown}/ and below (#{mode_label(mode)})")
      :granted
    when :parent_flat
      add_flat_dir(parent, mode)
      report.call(:ok, "#{parent_shown}/ direct children only (#{mode_label(mode)})")
      :granted
    when :parent_recursive
      add_dir(parent, mode)
      report.call(:ok, "#{parent_shown}/ and below (#{mode_label(mode)})")
      :granted
    else
      if note_text
        report.call(:fail, "denied (user's note: \"#{note_text}\")")
      else
        report.call(:fail, "denied")
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
    return :not_found unless (@grants[:r][:files] + @grants[:w][:files] + @grants[:d][:files]).include?(old_path)
    return :blocked   if sensitive?(new_path)

    [:r, :w, :d].each do |mode|
      list = @grants[mode][:files]
      had_grant = list.include?(old_path)
      list.reject! { |f| f == old_path || f == new_path }
      list << new_path if had_grant
    end
    :renamed
  end

  # Revoke every stored grant (all modes, all tiers) whose path is EXACTLY `path`,
  # returning how many entries were dropped. Called after a successful delete: a grant
  # on a removed path is stale, and grant_access returns :granted without a dialog for
  # an already-granted path, so a lingering grant would skip fresh consent if the path
  # is later re-created. Only the exact path is touched; an ancestor RECURSIVE grant
  # stays (the user granted that parent and it still covers everything else under it).
  def revoke_grants(path)
    path    = resolve(path)
    removed = 0
    %i[r w d].each do |mode|
      %i[files dirs flat_dirs].each do |tier|
        removed += 1 if @grants[mode][tier].delete(path)
      end
    end
    @audit_logger&.info "grants revoked for #{display_path(path)} (#{removed})" if removed.positive?
    removed
  end

  def clear
    [:r, :w, :d].each do |mode|
      @grants[mode][:files].clear
      @grants[mode][:dirs].clear
      @grants[mode][:flat_dirs].clear
    end
  end

  def empty?
    [:r, :w, :d].all? do |mode|
      @grants[mode][:files].empty? && @grants[mode][:dirs].empty? &&
        @grants[mode][:flat_dirs].empty?
    end
  end

  def size
    (@grants[:r][:files] + @grants[:w][:files]).uniq.size
  end

  # Total number of distinct access grants (files + directories, across all modes).
  def access_grant_count
    (@grants[:r][:files] + @grants[:w][:files] + @grants[:d][:files] +
     @grants[:r][:dirs] + @grants[:w][:dirs] +
     @grants[:r][:flat_dirs] + @grants[:w][:flat_dirs] +
     @grants[:d][:dirs] + @grants[:d][:flat_dirs]).uniq.size
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

  # True if the path is a direct child of (or equal to) any directory in the given
  # flat_dirs list. A flat grant covers the dir itself and its direct children, not deeper.
  def flat_dir_covers?(flat_dirs, path)
    return false if flat_dirs.empty?

    parent = File.dirname(path)
    flat_dirs.any? { |d| d == parent }
  end

  # True when the YOLO posture is ON. Public because /grant shows the coverage as a
  # POSTURE line - it is never a stored grant, so it must not reach #accessible_paths
  # (that list is what a session saves and restores, and consent posture is user-side state).
  def posture_active?
    !@posture.nil? && !!@posture.call
  end

  # The workdir display form of the scope the posture currently covers, for /grant.
  def posture_scope
    display_path(@workdir)
  end

  # The workdir-relative dirs the posture never auto-covers. Public so /grant can name them.
  def protected_dirs
    @protected_dirs
  end

  private

  # The YOLO coverage: a path INSIDE the working directory is covered for this mode
  # without a dialog. It never reaches a sensitive path (the caller already rejected it),
  # the owner's own space, or anything outside the workdir - a posture loosens consent
  # INSIDE the sandbox, never an escape from it. The workdir itself has no relative form,
  # so a nil rel is what makes the whole tree covered (that is the point of the posture).
  def posture_covers?(path, mode)
    unless posture_active?
      # A flip back ON must announce again - the flag is per posture, not per session.
      @posture_announced[mode] = false
      return false
    end
    return false unless within_workdir?(path)

    rel = relative_path(path)
    # A protected dir keeps its dialog in every posture.
    return false if rel && protected_space?(rel)

    announce_posture(mode)
    true
  end

  # True when a workdir-relative path lies inside any protected dir. Each dir uses the
  # exact-prefix shape SensitiveFiles.under_dir? applies to the zones, so a resolved path
  # that escaped it (local/../analysis) and a nested lookalike (lib/local) are not protected.
  def protected_space?(rel)
    @protected_dirs.any? { |dir| SensitiveFiles.under_dir?(rel, dir) }
  end

  # An auto-approval must leave a trace (a status line AND a harness.log line), the rule
  # YOLO's shell runs follow. Once per mode per session: file.list/file.search call readable?
  # on every candidate and dir.delete on every tree entry, so a per-access line buries the log.
  def announce_posture(mode)
    return if @posture_announced[mode]

    @posture_announced[mode] = true
    label = mode_label(mode)
    Tool.push_status(
      label: "access",
      verdict: :ok,
      message: "auto-granted (YOLO): #{label} in the working directory"
    )
    @audit_logger&.info "auto-granted (YOLO): #{label} access in #{@workdir}"
  end

  # True if the path itself (when it is a granted directory) or any of its ancestor
  # directories is present in the given list of granted directories.
  def ancestor_granted?(granted_dirs, path)
    return true if granted_dirs.include?(path)

    dir = File.dirname(path)
    loop do
      return true if granted_dirs.include?(dir)
      return false if dir == "/"

      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    false
  end

  def mode_label(mode)
    case mode
    when :r then "read"
    when :w then "write"
    when :d then "delete"
    else "read+write"
    end
  end

  def granted?(mode, tier, path)
    lists_for(mode, tier).include?(path)
  end

  # Grant a path under the given mode(s) and tier. With a block: applies the block to each
  # affected list (used by #remove).
  def grant(mode, tier, path = nil, &block)
    modes = mode == :rw ? %i[r w] : [mode].flatten
    modes.each do |m|
      next unless %i[r w d].include?(m)

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
    when :d then @grants[:d][tier].dup
    else (@grants[:r][tier] + @grants[:w][tier]).uniq
    end
  end
end
