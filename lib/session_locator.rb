# frozen_string_literal: true

require "json"
require "securerandom"

require_relative "harness_error"

# The single place that knows WHERE a session lives and WHICH session this run is. Pure
# path logic: it needs only the working directory. Identity is resolved here, BEFORE any
# derived resource (log, history, session dir) is built, so nothing is built under the wrong
# id. The layered (dir-per-job) layout this reads: doc/session_layers_design.md.
class SessionLocator
  HARNESS_DIR  = ".harness"
  SESSIONS_DIR = File.join(HARNESS_DIR, "sessions")
  # The session JSON lives inside its own directory (sessions/<id>/session.json).
  SESSION_FILE = "session.json"
  # A saved run directory holds system.json + jobs/<id>/...
  SYSTEM_FILE = "system.json"
  JOBS_DIR = "jobs"
  # A job's replay tail: the foreground buffer's saved entries, in the job dir (JobRegistry owns it).
  REPLAY_FILE = "replay.json"
  # A job's own record (kind, status, result and edges as ids), the detail system.json's jobs[] points at.
  JOB_FILE = "job.json"
  # Each session logs to its own file inside its session dir, so concurrent sessions in one
  # workdir do not interleave in a shared log.
  SESSION_LOG_FILE = "harness.log"
  # Characters of surrounding text #search shows around a match, so a hit reads as context
  # rather than a bare id. Fixed window - the whole conversation is never dumped, only these windows.
  SNIPPET_RADIUS = 80

  # session_id: the id the run's owner settled (its own resolve_id, or a saved
  # one). Every path this object names is under it, so a consumer is handed a
  # locator that already knows which run it points at - never an id to repeat.
  def initialize(workdir, session_id: nil)
    @workdir    = workdir
    @session_id = session_id
  end

  attr_reader :workdir
  attr_accessor :session_id

  def sessions_dir
    File.join(@workdir, SESSIONS_DIR)
  end

  def session_dir
    File.join(sessions_dir, @session_id)
  end

  # A path in the working directory as the model sees it (relative), so a spill the model is
  # told about is a path the USER can open.
  def relative_path(path)
    prefix = "#{@workdir}/"
    path.start_with?(prefix) ? path[prefix.length..] : path
  end

  def session_file_path
    File.join(session_dir, SESSION_FILE)
  end

  # -- Layered (dir-per-job) layout -------------------------------------------
  # A saved SYSTEM is a session directory holding system.json plus a jobs/<id>/ tree. These are
  # the path primitives the layered writer and reader build on; session_dirs / session_files
  # below address BOTH a layered system and a flat (one-file) session.
  def system_file_path
    File.join(session_dir, SYSTEM_FILE)
  end

  def job_dir(job_id)
    File.join(session_dir, JOBS_DIR, job_id.to_s)
  end

  # A job's conversation file. It carries NO session_id (a job is named by this path); the run
  # UUID lives in the dir name and system.json only.
  def job_session_file_path(job_id)
    File.join(job_dir(job_id), SESSION_FILE)
  end

  # A job's own record file (kind/status/result/edges), the detail system.json's jobs[] points at.
  def job_file_path(job_id)
    File.join(job_dir(job_id), JOB_FILE)
  end

  def job_replay_file_path(job_id)
    File.join(job_dir(job_id), REPLAY_FILE)
  end

  # True when the directory is a layered SYSTEM (it has system.json). A flat layout dir
  # (top-level session.json, no system.json) is not.
  def system_dir?
    File.file?(system_file_path)
  end

  # The session's own log file. It is part of WHERE a session lives, so it is spelled once here.
  def session_log_path
    File.join(session_dir, SESSION_LOG_FILE)
  end

  # Where one session's tool-result images are filed. The dir is configurable
  # (mcp_images.dir), so the base comes from the caller; the id part is this
  # object's business (ImageStore keys a resumed run's blobs to the same dir).
  def image_content_dir(base)
    File.join(base, @session_id.to_s)
  end

  # Session DIRECTORY names. The unit of a saved session is its directory, either the flat layout
  # (a top-level session.json) or a layered run (system.json + jobs/<id>/). Enumerating directories
  # - not a one-level session.json glob - lets both layouts coexist: a glob would return [] for a
  # layered system (its session.json is nested under jobs/). A stray loose file is not a directory.
  def session_dirs
    return [] unless File.directory?(sessions_dir)

    Dir.glob(File.join(sessions_dir, "*")).select do |dir|
      File.directory?(dir) && (File.file?(File.join(dir, SYSTEM_FILE)) ||
                               File.file?(File.join(dir, SESSION_FILE)))
    end
  end

  # The saved JSON that names each session directory: system.json for a layered system,
  # session.json for a flat session. Callers that need the directory take File.dirname.
  # #find_session_file / #list / #search / #newest_* all derive from this so both layouts
  # are addressed the same way.
  def session_files
    session_dirs.map do |dir|
      sys_path = File.join(dir, SYSTEM_FILE)
      File.file?(sys_path) ? sys_path : File.join(dir, SESSION_FILE)
    end
  end

  def newest_session_path
    session_files.max_by { |p| File.mtime(p) }
  end

  def find_session_file(id)
    raise HarnessError, "invalid session id: #{id}" unless valid_id?(id)

    # The id is the session DIRECTORY name, so an abbreviated id is matched by prefix.
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

  # The id THIS run must use, settled before anything is built from it: an existing session for
  # --resume / --continue, a fresh UUID otherwise. Raises rather than silently falling back to a
  # new id: a typo'd resume id must not quietly start an unrelated empty session the user thinks
  # is theirs, and raising here means NO directory was ever created for an unused id.
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

  # The saved conversation data of a session id (used to fill a session whose id is ALREADY
  # settled - which is why this returns data instead of doing the restore itself). A layered
  # system stores its data split across system.json and the job files; a flat session stores one
  # session.json. Both are reassembled into the SAME flat hash so resume consumers read one shape
  # regardless of layout - the layout stays the locator's knowledge. A flat session is read as
  # the degenerate one-job case: its flat file already IS that hash.
  def read_session
    path = find_session_file(@session_id)
    raise HarnessError, "no saved session matching '#{@session_id}' (see /sessions)" \
      unless path

    unless File.basename(path) == SYSTEM_FILE
      return JSON.parse(File.read(path), symbolize_names: true)
    end

    assemble_system
  end

  # The layered system record: system.json of a session directory, parsed symbolized. Raises
  # when the id has no system record (a flat session has none).
  def read_system
    path = find_session_file(@session_id)
    unless path && File.basename(path) == SYSTEM_FILE
      raise HarnessError, "no system record for session '#{@session_id}' (see /sessions)"
    end

    JSON.parse(File.read(path), symbolize_names: true)
  end

  # A job's conversation file (jobs/<id>/session.json), parsed symbolized. Raises when that job
  # has no conversation file (its dir was dropped, or it is the degenerate layout with no per-job tree).
  def read_job_session(job_id)
    path = job_session_file_path(job_id)
    unless File.file?(path)
      raise HarnessError, "no session for job #{job_id} of session '#{@session_id}'"
    end

    JSON.parse(File.read(path), symbolize_names: true)
  end

  # A job's own record (jobs/<id>/job.json): kind, status, result and edges as ids. Read by the
  # per-job resume path. Raises when the job has no record.
  def read_job_record(job_id)
    path = job_file_path(job_id)
    unless File.file?(path)
      raise HarnessError, "no job record for job #{job_id} of session '#{@session_id}'"
    end

    JSON.parse(File.read(path), symbolize_names: true)
  end

  # -- Per-job restore --------------------------------------------------------

  # EVERY retained job with a saved conversation dir: each job's own chain, kind, status and shown
  # tail, keyed by its SAVED id. No job is excluded - on restore no job is foreground yet; the
  # system owner rebuilds these jobs with their saved ids, then decides which is foreground. Each
  # entry is {id:, kind:, status:, messages:, replay_tail:}; a job whose dir was dropped has no
  # entry. A flat session has no per-job tree so contributes nothing (read_system would raise -
  # hence the system_dir? guard). Reading a saved file is main-safe; putting these into live jobs
  # is the system owner's.
  def job_restores
    return [] unless system_dir?

    Array(read_system[:jobs]).filter_map do |entry|
      job_id = entry[:id]
      next if job_id.nil?
      next unless File.file?(job_session_file_path(job_id))

      # Status and kind come from the job's OWN record (job.json is what a save writes them into);
      # the index entry names the job, the record describes it.
      record_data = parse_json(job_file_path(job_id)) || {}
      {
        id: job_id,
        kind: record_data[:kind] || entry[:kind],
        status: record_data[:status] || entry[:status],
        session: parse_json(job_session_file_path(job_id)) || {},
        replay_tail: Array(parse_json(job_replay_file_path(job_id)))
      }
    end
  end

  # Saved sessions, newest first (pure data; Commands::SessionsCommand is the single renderer of
  # this shape, so /sessions and --list-sessions show the same columns from the same source). An
  # unreadable file is skipped rather than failing the whole listing.
  def list
    session_files.sort_by { |p| File.mtime(p) }.reverse.map do |path|
      id   = File.basename(File.dirname(path))
      data = entry_data(path)
      jobs = job_breakdown(data)
      {
        id:,
        path:,
        saved_at: File.mtime(path),
        messages: jobs.sum { |j| j[:messages] },
        job_breakdown: jobs,
        files:    grant_count(data),
        jobs:     jobs.size,
        workdir:  data[:workdir]
      }
    rescue StandardError
      nil
    end.compact
  end

  # Saved sessions whose CONTENT mentions a query. The point is to let the model answer "which
  # session was I doing X in?" - /sessions only shows counts. Matches the id and every message's
  # text, case-insensitively, by substring. Each hit carries a snippet around the first match so
  # the model can tell sessions apart without reading them whole. An unreadable file is skipped,
  # like #list. Newest first.
  def search(query)
    q = query.to_s.strip.downcase
    return [] if q.empty?

    session_files.sort_by { |p| File.mtime(p) }.reverse.filter_map do |path|
      id   = File.basename(File.dirname(path))
      data = begin
        entry_data(path)
      rescue StandardError
        nil
      end
      next if data.nil?

      matches = match_all(id, data, File.dirname(path), q)
      next if matches.empty?

      {
        id:,
        path:,
        saved_at:   File.mtime(path),
        messages:   job_breakdown(data).sum { |j| j[:messages] },
        workdir:    data[:workdir],
        hits:       matches.size,
        snippet:    matches.first
      }
    end
  end

  private

  # The data hash of one session ENTRY file for the list/search side: system.json for a layered
  # system (its recorded jobs carry each job's conversation size), or the flat session.json as-is.
  # Resume keeps its own assemble_system - a listing never needs the conversation folded back in.
  def entry_data(path)
    JSON.parse(File.read(path), symbolize_names: true)
  end

  # The system half of a layered resume: system.json AS IS (identity, postures, access, file_cache,
  # foreground, jobs, next_id). It carries NO job conversation - the system's owner reads each job's
  # own files and restores them job by job. Which job is foreground is the system owner's decision,
  # not the locator's.
  def assemble_system
    read_system
  end

  # -- Reading helpers -------------------------------------------------------

  # Parse a JSON file symbolized, or nil when it does not exist. Used for a job's replay.json so
  # the assembled replay_tail is symbol-keyed like every other resume_data value.
  def parse_json(path)
    return nil unless path && File.file?(path)

    JSON.parse(File.read(path), symbolize_names: true)
  end

  # [{id:, messages:}] for one session: the per-job conversation sizes a save records in system.json's
  # job entries (no job-file reads). A flat session is the degenerate one-job case, read from its own messages.
  def job_breakdown(data)
    return Array(data[:jobs]).map do |job|
      { id: job[:id], messages: job[:messages].to_i }
    end if data.key?(:jobs)

    [{ id: 0, messages: (data[:messages] || []).size }]
  end

  # A modern save keeps grants under the per-mode access hash; a legacy file used the flat
  # files/dirs/trees lists. Count the union of distinct paths.
  def grant_count(data)
    access = data[:access] || data["access"]
    return legacy_grant_count(data) unless access.is_a?(Hash)

    paths = []
    %w[both read write delete].each do |section_key|
      section = access[section_key.to_sym] || access[section_key] || {}
      %w[files dirs flat_dirs].each do |tier|
        paths.concat(Array(section[tier.to_sym] || section[tier]))
      end
    end
    paths.uniq.size
  end

  def legacy_grant_count(data)
    (Array(data[:files]) + Array(data[:dirs]) + Array(data[:trees])).uniq.size
  end

  def valid_id?(id)
    !id.to_s.strip.empty? && id.to_s.match?(/\A[0-9a-fA-F-]+\Z/)
  end

  # Where a query appears in one session: the id, then every job's message text. A layered system
  # stores each conversation in its own jobs/<id>/session.json, so a search reads them all (a
  # sub-agent transcript must be findable, not just the foreground's). One snippet per matching location.
  def match_all(id, data, session_dir, query)
    found = []
    found << snippet(id.to_s, query) if id.to_s.downcase.include?(query)
    job_texts(data, session_dir).each do |content|
      text = content.to_s
      found << snippet(text, query) if text.downcase.include?(query)
    end
    found
  end

  # The message contents of every conversation a session owns: the flat file for a flat session,
  # every retained job's session.json for a layered system.
  # A layered system records each job's size in system.json but keeps the text in
  # the job's own file under the session dir the entry file lives in.
  def job_texts(data, session_dir)
    return Array(data[:messages]).map { |m| m[:content] } unless data.key?(:jobs)

    Array(data[:jobs]).flat_map do |job|
      path = File.join(session_dir, JOBS_DIR, job[:id].to_s, SESSION_FILE)
      File.file?(path) ? Array(parse_json(path)[:messages]).map { |m| m[:content] } : []
    end
  end

  # A compact window of text centred on the first case-insensitive occurrence of the query, with
  # leading/trailing ellipses when the real text is longer.
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
