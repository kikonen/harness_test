# frozen_string_literal: true

require "json"
require "securerandom"

require_relative "harness_error"

# -- SessionLocator ---------------------------------------------------------
#
# The single place that knows WHERE a session lives and WHICH session this
# run is. Pure path logic: it needs the working directory and nothing else -
# no Harness, no LLM client, no logger.
#
# WHY THIS EXISTS (issue #276): a session id is identity, and almost every
# piece of harness state is DERIVED from it (the log file, the history file,
# the session directory). The old bootstrap minted a fresh random id inside
# Session#initialize, built the logger and the client under it, and only
# afterwards let --resume / --continue swap in a different saved id - so every
# derived resource had to be chased and re-pointed afterwards (issues #113,
# #119, #123, #135, #270). That rebind chase was a construction-order bug, not
# a logging bug. Resolving identity here, BEFORE anything is constructed, is
# what makes the whole rebind machinery unnecessary: the id is never wrong, so
# no resource is ever built under the wrong one.
class SessionLocator
  HARNESS_DIR  = ".harness"
  SESSIONS_DIR = File.join(HARNESS_DIR, "sessions")
  # issue #207: the session JSON lives INSIDE its own directory
  # (.harness/sessions/<id>/session.json), alongside its log and history.
  SESSION_FILE = "session.json"
  # issue #548 (dir per job): a saved run directory holds run.json + jobs/<id>/...
  RUN_FILE = "run.json"
  JOBS_DIR = "jobs"
  # A job's replay tail (issue #548): the foreground buffer's saved entries,
  # moved into the job dir on ownership grounds (JobRegistry owns it, not Session).
  REPLAY_FILE = "replay.json"
  # issue #113: each session logs to its own file inside its session dir, so
  # concurrent sessions in one workdir do not interleave in a shared log.
  SESSION_LOG_FILE = "harness.log"
  # issue #279: characters of surrounding text #search shows around a match,
  # so a hit reads as context rather than a bare id. Fixed window - the whole
  # conversation is never dumped to the model, only these windows.
  SNIPPET_RADIUS = 80

  def initialize(workdir)
    @workdir = workdir
  end

  attr_reader :workdir

  def sessions_dir
    File.join(@workdir, SESSIONS_DIR)
  end

  def session_file_path(id)
    File.join(sessions_dir, id, SESSION_FILE)
  end

  # -- Layered (dir-per-job) layout (issue #548) ----------------------------
  # A saved RUN is a session directory holding run.json plus a jobs/<id>/ tree.
  # These are the path primitives a writer/resolver build on. They do NOT yet
  # replace the #207 #session_file_path / #session_files glob: the listing glob
  # is rewritten in the same step that switches the writer, so old and new
  # layouts stay listable at once (see doc/session_layers_design.md).
  def run_file_path(id)
    File.join(sessions_dir, id, RUN_FILE)
  end

  def job_dir_path(id, job_id)
    File.join(sessions_dir, id, JOBS_DIR, job_id.to_s)
  end

  # A job's conversation file. It carries NO session_id (a job is named by this
  # path, doc/session_layers_design.md); the run UUID lives in the dir name and
  # run.json only.
  def job_session_file_path(id, job_id)
    File.join(job_dir_path(id, job_id), SESSION_FILE)
  end

  def job_replay_file_path(id, job_id)
    File.join(job_dir_path(id, job_id), REPLAY_FILE)
  end

  # True when the directory is a layered RUN (it has run.json). A #207 layout
  # dir (top-level session.json, no run.json) is not.
  def run_dir?(id)
    File.file?(run_file_path(id))
  end

  # The session's own log file (issue #113). It is part of WHERE a session
  # lives, so it is spelled once, here.
  def session_log_path(id)
    File.join(sessions_dir, id, SESSION_LOG_FILE)
  end

  # Session DIRECTORY names (issue #548). The unit of a saved session is its
  # directory, which is either the #207 layout (a top-level session.json) or a
  # layered RUN (a run.json + jobs/<id>/). Enumerating directories - not a
  # one-level session.json glob - is what lets both layouts coexist: the old
  # glob returned [] for a layered run (its session.json is nested under jobs/),
  # which would break /sessions, --resume, --continue and --delete-session the
  # moment the writer switched layouts. A stray loose file is not a directory.
  def session_dirs
    return [] unless File.directory?(sessions_dir)

    Dir.glob(File.join(sessions_dir, "*")).select do |dir|
      File.directory?(dir) && (File.file?(File.join(dir, RUN_FILE)) ||
                               File.file?(File.join(dir, SESSION_FILE)))
    end
  end

  # The saved JSON that names each session directory: run.json for a layered run,
  # session.json for a #207 session. Callers that need the directory take
  # File.dirname of the path. #find_session_file / #list / #search / #newest_*
  # all derive from this so both layouts are addressed the same way.
  def session_files
    session_dirs.map do |dir|
      run = File.join(dir, RUN_FILE)
      File.file?(run) ? run : File.join(dir, SESSION_FILE)
    end
  end

  def newest_session_path
    session_files.max_by { |p| File.mtime(p) }
  end

  def find_session_file(id)
    raise HarnessError, "invalid session id: #{id}" unless valid_id?(id)

    # issue #207: the id is the session DIRECTORY name, so an abbreviated id
    # is matched by prefix.
    matches = session_files.select do |p|
      File.basename(File.dirname(p)).downcase.start_with?(id.to_s.downcase)
    end

    case matches.size
    when 0 then nil
    when 1 then matches.first
    else
      found = matches.map { |p| File.basename(File.dirname(p)) }.join(", ")
      raise HarnessError, "ambiguous session id '#{id}' - matches: #{found}"
    end
  end

  # -- Identity resolution (the point of this class) -------------------------

  # The id THIS run must use, settled before anything is built from it:
  # an existing session for --resume / --continue, a fresh UUID otherwise.
  # Raises rather than silently falling back to a new id: a typo'd resume id
  # must not quietly start an unrelated empty session the user thinks is
  # theirs, and (unlike the old order) raising here means NO directory was
  # ever created for an id this run does not use.
  def resolve_id(resume: nil, newest: false)
    return newest_id if newest
    return find_id!(resume) if resume

    fresh_id
  end

  def fresh_id
    SecureRandom.uuid
  end

  # The full directory name of a (possibly abbreviated) saved session id.
  def find_id!(id)
    path = find_session_file(id)
    raise HarnessError, "no saved session matching '#{id}' (see /sessions)" unless path

    File.basename(File.dirname(path))
  end

  def newest_id
    path = newest_session_path
    raise HarnessError,
          "no saved sessions in #{sessions_dir} to continue (use /sessions)" \
      unless path

    File.basename(File.dirname(path))
  end

  # The saved conversation data of a session id (used to fill a session whose
  # id is ALREADY settled - which is why this returns data instead of doing
  # the restore itself).
  #
  # A layered RUN (issue #548) stores its data split across run.json and the
  # foreground job's files; a #207 session stores one flat session.json. Both
  # are reassembled into the SAME flat hash so the resume consumers (Harness#
  # restore, apply_resume_state, CLI#setup) read one shape regardless of layout
  # - the layout stays the locator's knowledge, not the caller's. A #207 session
  # is read as the degenerate one-job case: its flat file already IS that hash.
  def read_session(id)
    path = find_session_file(id)
    raise HarnessError, "no saved session matching '#{id}' (see /sessions)" unless path

    session_id = File.basename(File.dirname(path))
    return JSON.parse(File.read(path), symbolize_names: true) unless run_dir?(session_id)

    assemble_run(session_id)
  end

  # The layered run record (issue #548): run.json of a session directory, parsed
  # symbolized. Raises when the id has no run record (a #207 session has none).
  def read_run(id)
    path = run_file_path(id)
    unless File.file?(path)
      raise HarnessError, "no run record for session '#{id}' (see /sessions)"
    end

    JSON.parse(File.read(path), symbolize_names: true)
  end

  # A job's conversation file (jobs/<id>/session.json), parsed symbolized. Raises
  # when that job has no conversation file (its dir was dropped, or it is the
  # degenerate layout with no per-job tree).
  def read_job_session(id, job_id)
    path = job_session_file_path(id, job_id)
    unless File.file?(path)
      raise HarnessError, "no session for job #{job_id} of session '#{id}'"
    end

    JSON.parse(File.read(path), symbolize_names: true)
  end

  # Saved sessions, newest first (pure data; Commands::SessionsCommand is the
  # single renderer of this shape, so /sessions and --list-sessions show the
  # same columns from the same source). An unreadable file is skipped rather
  # than failing the whole listing.
  def list
    session_files.sort_by { |p| File.mtime(p) }.reverse.map do |path|
      data = JSON.parse(File.read(path), symbolize_names: true)
      {
        id:       File.basename(File.dirname(path)),
        path:,
        saved_at: File.mtime(path),
        messages: (data[:messages] || []).size,
        files:    (data[:files] || []).size,
        workdir:  data[:workdir]
      }
    rescue StandardError
      nil
    end.compact
  end

  # Saved sessions whose CONTENT mentions a query (issue #279). The point is to
  # let the model answer "which session was I doing X in?" - /sessions only
  # shows counts, so the only way to find a session by what it was ABOUT was to
  # open each one. Matches the id and every message's text, case-insensitively,
  # by substring. Each hit carries a snippet around the first match so the
  # model can tell the sessions apart without reading them whole. An unreadable
  # file is skipped, the same as #list. Newest first, like #list.
  def search(query)
    q = query.to_s.strip.downcase
    return [] if q.empty?

    session_files.sort_by { |p| File.mtime(p) }.reverse.filter_map do |path|
      data = begin
        JSON.parse(File.read(path), symbolize_names: true)
      rescue StandardError
        nil
      end
      next if data.nil?

      id      = File.basename(File.dirname(path))
      matches = match_locations(data, id, query: q)
      next if matches.empty?

      {
        id:,
        path:,
        saved_at:   File.mtime(path),
        messages:   (data[:messages] || []).size,
        workdir:    data[:workdir],
        hits:       matches.size,
        snippet:    matches.first
      }
    end
  end

  private

  # Re-join a layered run into the flat resume_data hash: run.json supplies the
  # run/world keys (identity, postures, access, file_cache, foreground, jobs),
  # the foreground job's session.json supplies its conversation and per-agent
  # model state, replay.json supplies the saved tail. Disjoint by construction,
  # so a plain merge is the whole assembly. A foreground job whose dir was
  # dropped contributes nothing (an empty conversation) - the run-level state
  # still restores.
  def assemble_run(session_id)
    run    = read_run(session_id)
    fg     = run[:foreground_job]
    merged = run.dup
    if fg && File.file?(job_session_file_path(session_id, fg))
      merged.merge!(read_job_session(session_id, fg))
    end
    replay_path = job_replay_file_path(session_id, fg) if fg
    merged[:replay_tail] = parse_json(replay_path) || []
    merged
  end

  # Parse a JSON file symbolized, or nil when it does not exist. Used for the
  # job's replay.json so the assembled replay_tail is symbol-keyed like every
  # other resume_data value (the resume side re-symbols entry type/origin).
  def parse_json(path)
    return nil unless path && File.file?(path)

    JSON.parse(File.read(path), symbolize_names: true)
  end

  def valid_id?(id)
    !id.to_s.strip.empty? && id.to_s.match?(/\A[0-9a-fA-F-]+\Z/)
  end

  # Where a query appears in one session: the id, then each message content.
  # Returns one snippet per location that matches, so a session that mentions
  # the query several times reports its hit count but the model still only
  # sees compact windows, not the whole conversation.
  def match_locations(data, id, query:)
    found = []
    found << snippet(id.to_s, query) if id.to_s.downcase.include?(query)
    (data[:messages] || []).each do |msg|
      text = msg[:content].to_s
      found << snippet(text, query) if text.downcase.include?(query)
    end
    found
  end

  # A compact window of text centred on the first case-insensitive occurrence
  # of the query, with leading/trailing ellipses when the real text is longer.
  def snippet(text, query)
    down = text.downcase
    at   = down.index(query)
    return text unless at

    start = [at - SNIPPET_RADIUS, 0].max
    stop  = [at + query.length + SNIPPET_RADIUS, text.length].min
    head  = start.zero? ? "" : "..."
    tail  = stop == text.length ? "" : "..."
    "#{head}#{text[start...stop]}#{tail}"
  end
end
