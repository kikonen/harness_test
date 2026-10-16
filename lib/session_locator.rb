# frozen_string_literal: true

require 'json'
require 'securerandom'

require_relative 'harness_error'

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
  HARNESS_DIR  = '.harness'
  SESSIONS_DIR = File.join(HARNESS_DIR, 'sessions')
  # issue #207: the session JSON lives INSIDE its own directory
  # (.harness/sessions/<id>/session.json), alongside its log and history.
  SESSION_FILE = 'session.json'
  # issue #113: each session logs to its own file inside its session dir, so
  # concurrent sessions in one workdir do not interleave in a shared log.
  SESSION_LOG_FILE = 'harness.log'

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

  # The session's own log file (issue #113). It is part of WHERE a session
  # lives, so it is spelled once, here.
  def session_log_path(id)
    File.join(sessions_dir, id, SESSION_LOG_FILE)
  end

  # All saved session files (issue #207 layout: <sessions>/<id>/session.json).
  def session_files
    return [] unless File.directory?(sessions_dir)

    Dir.glob(File.join(sessions_dir, '*', SESSION_FILE)).select { |p| File.file?(p) }
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
      found = matches.map { |p| File.basename(File.dirname(p)) }.join(', ')
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
  def read_session(id)
    path = find_session_file(id)
    raise HarnessError, "no saved session matching '#{id}' (see /sessions)" unless path

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
        path:     path,
        saved_at: File.mtime(path),
        messages: (data[:messages] || []).size,
        files:    (data[:files] || []).size,
        workdir:  data[:workdir]
      }
    rescue StandardError
      nil
    end.compact
  end

  private

  def valid_id?(id)
    !id.to_s.strip.empty? && id.to_s.match?(/\A[0-9a-fA-F-]+\Z/)
  end
end
