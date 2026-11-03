# frozen_string_literal: true

require "digest"

require_relative "sensitive_files"
require_relative "ui/dialog"
require_relative "tool"

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
#   * deleting              -> DELETE grant on the affected path (or parent
#                              dir for dir.delete) - a separate mode, NOT
#                              implied by read or write (issue #92)
#
# For dir.create the grant dialog offers the TARGET DIRECTORY ITSELF as the
# first option (issue #54), so granting does not make existing siblings of
# the parent writeable.
#
# A write grant implies read access to the same path (writing a file
# requires reading it back), but a read grant never implies write.
#
# DELETE is its own independent mode: a read or write grant does NOT imply
# delete, and a delete grant does not imply read or write. It is granted,
# persisted, and displayed with the same options as read/write (issue #92).
#
# POSTURE COVERAGE (issue #274): when the user has the YOLO posture on, a path
# INSIDE the working directory is covered for read, write and delete without a
# dialog. This is a coverage rule consulted live on every check, NOT a stored
# grant - turning the posture off stops the coverage at once, and /grant shows it
# as a posture line rather than as a grant. It never reaches a sensitive path,
# never reaches the owner's own space (local/), and never reaches a path outside
# the working directory.
#
# Sensitive paths (.git, .harness, .env*) are blocked regardless of grants,
# EXCEPT inside a per-issue scratch zone (tmp/scratch/<n>/, tmp/keep/<n>/),
# where a nested one is a disposable clone, not this project's state.
#
# All paths are resolved relative to the working directory (@workdir).
# Path containment is decided on canonical paths (File.expand_path),
# so ".." segments and separator mismatches are handled correctly.
class FileList
  include Enumerable

  # Permission modes.
  MODES = %i[r w d rw].freeze

  # Characters Dir.glob expands (braces, brackets, wildcards). A segment holding
  # one is no longer a directory name, which is what glob_base_dir splits on.
  GLOB_METACHARS = /[\[\]*?{}]/
  # Both separators: an expanded path uses "/", a pattern may carry "\".
  PATH_SEPARATORS = %r{[/\\]}

  # The YOLO posture reader (Harness#yolo?), wired by Harness#initialize the way
  # the command runner reads the same posture live. Read on EVERY check: a /yolo
  # typed at the idle prompt, or flipped mid-turn, applies to the very next tool
  # call, and switching it off removes the coverage at once. nil = no posture.
  attr_accessor :posture

  # The session logger the posture coverage reports itself to (issue #274: an
  # auto-approval must leave a trace, the same rule YOLO's shell runs follow).
  # Set by Harness#initialize after its own logger exists.
  attr_accessor :audit_logger

  # One audit line per MODE per session, not per access: file.list and
  # file.search call readable? on every candidate file, and a covered workdir
  # would print hundreds of identical lines.
  attr_reader :posture_announced

  def self.sha256(path)
    return nil unless File.file?(path)

    Digest::SHA256.file(path).hexdigest
  end

  attr_reader :workdir

  def initialize(initial = [], workdir: Dir.pwd, protected_dirs: nil)
    @workdir = File.expand_path(workdir)
    # grants[mode] -> { files: [...], dirs: [...] } of canonical paths.
    # "dirs" grants are recursive (cover every file under the directory).
    # "flat_dirs" grants are non-recursive (dir itself + direct children).
    @grants = { r: { files: [], dirs: [], flat_dirs: [] },
                w: { files: [], dirs: [], flat_dirs: [] },
                d: { files: [], dirs: [], flat_dirs: [] } }
    @posture = nil
    @posture_announced = { r: false, w: false, d: false }
    # Workdir-relative dirs the posture never auto-covers (issue #385): a human
    # grant may still cover them, but an auto-approval must not quietly remove the
    # veto the user kept there. nil = the default (the owner's space, local/);
    # the config 'protected_dirs:' key supplies the list.
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

  # True when the path lies inside a per-issue scratch zone (tmp/scratch/<n>/
  # or tmp/keep/<n>/). The zone test needs the RELATIVE path - tmp/ is where
  # the zones live in a project - and #relative_path has already resolved any
  # ".." away, so a zone name used as an escape route does not match.
  def scratch_zone?(path)
    SensitiveFiles.scratch_zone?(relative_path(path))
  end

  # The single decision point for "blocked whatever the grants": a sensitive NAME,
  # unless the path sits inside a scratch zone (a nested .git there is a disposable
  # clone) or inside the project's own skills directory (repo content the owner
  # chose to keep in .harness/skills) - where only a .env* NAME still blocks, since
  # the exemption lifts the .harness component and never the secret-file rule.
  # doc/sensitive_paths_design.md, doc/skills_design.md.
  def sensitive?(path)
    rel = relative_path(path)
    return false if SensitiveFiles.scratch_zone?(rel)
    return SensitiveFiles.env_named?(path) if SensitiveFiles.skills_zone?(rel)

    SensitiveFiles.sensitive?(path)
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

  # True if the path is writable: a write grant on the file itself or on any
  # ancestor directory (recursive). Sensitive paths are never accessible.
  # A read grant does NOT imply write access.
  def writable?(path)
    path = resolve(path)
    return false if sensitive?(path)
    return true  if posture_covers?(path, :w)

    return true  if @grants[:w][:files].include?(path)
    return true  if @grants[:w][:flat_dirs].include?(path)
    return true  if flat_dir_covers?(@grants[:w][:flat_dirs], path)

    ancestor_granted?(@grants[:w][:dirs], path)
  end

  # True if the path is deletable: a DELETE grant on the file itself or on
  # any ancestor directory (recursive). Sensitive paths are never accessible.
  # A read or write grant does NOT imply delete - delete is its own mode
  # (issue #92).
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

  # The directory a glob pattern points at - what listing it needs READ on.
  # Derived from the pattern's SEGMENTS, because only a plain wildcard is
  # strippable from a string: a brace or bracket glob ('{lib,spec}/*') has no
  # leading '*', so cutting at the first metacharacter asks for a directory
  # that does not exist (issue #152, analysis/152/repro.rb). A pattern with no
  # metacharacter at all is an ordinary path: a directory is its own base, a
  # file needs its parent.
  def glob_base_dir(pattern)
    expanded = resolve(pattern.to_s)
    segments = expanded.split(PATH_SEPARATORS)
    literal  = segments.take_while { |segment| !GLOB_METACHARS.match?(segment) }

    return expanded if literal.size == segments.size && File.directory?(expanded)
    return File.dirname(expanded) if literal.size == segments.size

    resolve(literal.join("/"))
  end

  # Summary of all grants, grouped by effective access. Each section is a
  # list of canonical paths; "both" (granted for read AND write) is listed
  # first and excluded from the read-only / write-only sections, so no path
  # appears twice there. Delete is an independent section (issue #92): a
  # path granted for delete may also appear under read/write. Used by the
  # CLI display, the user prompt, and /session.
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
  # mode: :r (read), :w (write), :d (delete), or :rw (read + write; default).
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

    return :granted if mode == :r && readable?(path)
    return :granted if mode == :w && writable?(path)
    return :granted if mode == :d && deletable?(path)
    return :blocked if sensitive?(path)

    verb = case mode
           when :r then "read access"
           when :d then "delete access"
           else "write access"
           end

    # inside/outside is decided on PATH LOCATION (a not-yet-existing path is
    # still inside if it resolves under the workdir); is_dir picks dir- vs
    # file-style options; a path that does not exist yet AND is being written
    # takes the create (target-first) ladder - see the options branch below.
    is_dir = File.directory?(path)
    inside = within_workdir?(path)

    parent       = File.dirname(path)
    parent_shown = display_path(parent)

    # issue #384: plain-language, WIDEST-FIRST choices. The user reads a scope
    # ladder (project > whole directory > just this) instead of decoding
    # "(dir only)" vs "(recursive)". An option is dropped when it would do
    # exactly what a wider one already does. The project-wide option is offered
    # only when the workdir itself is not a sensitive path (a workdir under
    # .git/.harness has no grantable project-wide scope).
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
      # A path being CREATED (dir.create, or a write to a not-yet-existing file):
      # issue #54 keeps the new path offered FIRST (narrow-first on purpose), so
      # granting it does NOT make the parent's existing siblings writeable. A
      # parent that IS the project reads as "the project", not "./".
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
      # A file inside the workdir: project > parent (whole dir) > this file.
      # The parent option is dropped when the parent IS the project root (it
      # would equal the project option). A parent "direct children only" grant
      # is no longer offered for a single file - issue #384 drops that tier.
      file_opts = []
      file_opts << project if project
      whole = whole_dir.call(parent, parent_shown)
      file_opts << whole if whole
      file_opts << UI::Dialog::Option.new(title: "Allow only this file", value: :file)
      file_opts
    else
      # Outside the workdir: the project-wide ladder does not apply (there is no
      # project scope over an outside path). A directory keeps its two grant
      # levels (whole tree / direct children only - the same capability the
      # pre-#384 dialog had); a single outside file is just "Allow". The
      # OUTSIDE-the-workdir warning below is what the user weighs here.
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

    # Each note line states its KIND (issue #388): the purpose is context, the
    # outside-the-workdir warning is the line the user must weigh before
    # granting - so the console can tell them apart without a regex.
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

    # The user may attach a one-line reason to the CANCEL choice
    # ("<cancel number> <reason>"); the dialog then returns
    # [CANCEL_VALUE, reason]. Unwrap it - the reason is just feedback on
    # the denial (issue #79), the selection itself drives the grant.
    note_text = choice.is_a?(Array) ? choice[1] : nil
    choice    = choice[0] if choice.is_a?(Array)
    # Feedback line. grant_access runs on the task thread, so this must go
    # through the task's event queue, never a bare puts onto $stdout from the
    # wrong thread (issue #40). "access" is the bracket label the renderer
    # will put back on the line.
    report = lambda do |verdict, message|
      Tool.push_status(label: "access", verdict:, message:)
    end
    case choice
    when :target
      add_file(path, mode)
      report.call(:ok, "#{shown}/ (dir itself only, #{mode_label(mode)})")
      :granted
    when :workdir
      # issue #384: the project-wide choice. Same tier as #seed_standing_grant
      # uses, so a grant chosen here behaves exactly like the config default.
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

  # Revoke every stored grant (all modes, all tiers) whose path is EXACTLY
  # `path`, and return how many grant entries were dropped. Called after a
  # successful delete (issue #105): a grant on a path that has just been
  # removed is stale, and grant_access returns :granted without a dialog when
  # a path is already granted - so a lingering grant would skip fresh consent
  # if the same path is later re-created. Only the exact path is touched; an
  # ancestor RECURSIVE grant (a different path string) stays, because the
  # user granted that parent and it still covers everything else under it.
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

  # Total number of distinct access grants (files + directories, across
  # both read and write modes).
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

  # True if the path is a direct child of (or equal to) any directory in the
  # given flat_dirs list. A flat grant covers the dir itself and its direct
  # children, but NOT deeper nesting.
  def flat_dir_covers?(flat_dirs, path)
    return false if flat_dirs.empty?

    parent = File.dirname(path)
    flat_dirs.any? { |d| d == parent }
  end

  # True when the YOLO posture is ON (issue #274). Public because /grant shows the
  # coverage as a POSTURE line - it is never a stored grant, so it must not reach
  # #accessible_paths (that list is what a session saves and restores, and consent
  # posture is user-side state, never conversation state).
  def posture_active?
    !@posture.nil? && !!@posture.call
  end

  # The workdir display form of the scope the posture currently covers, for /grant.
  def posture_scope
    display_path(@workdir)
  end

  # The workdir-relative dirs the posture never auto-covers (issue #385). Public
  # so /grant can name them.
  def protected_dirs
    @protected_dirs
  end

  private

  # The YOLO coverage (issue #274): a path INSIDE the working directory is covered
  # for this mode without a dialog. Three things it never reaches: a sensitive path
  # (the caller already rejected it), the owner's own space, and anything outside the
  # working directory - a posture loosens consent INSIDE the sandbox, never an escape
  # from it. The workdir itself has no relative form, so a nil rel is what makes the
  # whole tree covered (that is the point of the posture).
  def posture_covers?(path, mode)
    unless posture_active?
      # A flip back ON must announce again - the flag is per posture, not per session.
      @posture_announced[mode] = false
      return false
    end
    return false unless within_workdir?(path)

    rel = relative_path(path)
    # A protected dir (issue #385) keeps its dialog in every posture.
    return false if rel && protected_space?(rel)

    announce_posture(mode)
    true
  end

  # True when a workdir-relative path lies inside any protected dir (issue #385).
  # Each dir uses the exact-prefix shape SensitiveFiles.under_dir? applies to the
  # zones, so a resolved path that escaped it (local/../analysis) and a nested
  # lookalike (lib/local) are not protected.
  def protected_space?(rel)
    @protected_dirs.any? { |dir| SensitiveFiles.under_dir?(rel, dir) }
  end

  # An auto-approval must leave a trace, the rule YOLO's shell runs follow (issue
  # #221): a status line AND a harness.log line, so every access that ran without
  # asking is recoverable from the session log - including the posture that allowed
  # it. Once per mode per session: file.list and file.search call readable? on every
  # candidate and dir.delete on every entry of a tree, so a per-access line buries
  # the log in repeats.
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

  # True if the path itself (when it is a granted directory) or any of its
  # ancestor directories is present in the given list of granted directories.
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

  # Grant a path under the given mode(s) and tier.
  # With a block: applies the block to each affected list (used by #remove).
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
