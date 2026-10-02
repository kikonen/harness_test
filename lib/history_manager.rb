# frozen_string_literal: true

require 'fileutils'
require 'reline'

# Manages persistence of Reline's command history to a file inside the
# harness working directory. One entry per line, with backslashes and
# newlines escaped so multiline entries survive the round trip.
#
# issue #119: the history is PER SESSION. Each session id gets its own
# file (.harness/sessions/<session-id>/harness_history), so switching
# sessions (/resume) or starting a fresh one never mixes entries from
# different sessions, and concurrent runs in the same workdir can no
# longer overwrite each other's history file. The legacy shared file
# (.harness/harness_history) is still supported for reading: a session
# that has no file of its own yet starts from it, and the next save
# writes to the per-session location (the old file is left in place).
class HistoryManager
  # Legacy shared history file (relative to workdir/.harness/), kept as a
  # read-only fallback for sessions created before issue #119.
  LEGACY_FILENAME = 'harness_history'

  def initialize(workdir)
    @workdir      = workdir
    @history_file = resolve_file # legacy shared file until #bind_session
    @current_id   = nil
  end

  # Persisted history file for the CURRENT session id (the save target).
  attr_reader :history_file

  # Point this manager at a session id (issue #119). The history file is
  # resolved immediately, so the id only needs to be set before load/save
  # - typically right after a resume or /session-clear.
  def bind_session(session_id)
    @current_id   = session_id
    @history_file = resolve_file
  end

  # Load persisted history into Reline (best-effort).
  def load
    file = read_file
    return unless file && File.exist?(file)

    Reline::HISTORY.clear
    File.foreach(file) do |line|
      entry = line.chomp
      next if entry.empty?

      Reline::HISTORY << unescape(entry)
    end
  rescue StandardError => e
    puts e.message
    puts e.backtrace.join("\n")
    # Corrupt or unreadable history - start fresh.
  end

  # Persist current Reline history to disk (best-effort).
  # issue #135: Reline::HISTORY is GLOBAL to the process. When a run
  # resumes a saved session, the /resume command itself is already in it -
  # so "is the buffer empty?" cannot tell us whether this NEW random
  # session id has any history of its own. The guard must compare against
  # what THIS session id has already persisted: if every entry in the
  # buffer is already present in this session's file, writing would only
  # leave a dummy dir behind (a fresh process per resume gets a new random
  # id, and that dir would just hold the loaded other-session entries).
  # If even one entry is new to this session, the whole buffer is saved so
  # later arrow-key navigation in the same run stays complete.
  def save
    file = @history_file
    return unless has_new_entry?(file)

    FileUtils.mkdir_p(File.dirname(file))
    File.open(file, 'w') do |f|
      Reline::HISTORY.each do |entry|
        f.puts escape(entry)
      end
    end
  rescue StandardError => e
    puts e.message
    puts e.backtrace.join("\n")
    # Ignore - history persistence is best-effort.
  end

  private

  # True when the Reline buffer holds at least one entry that this
  # session id has not persisted yet (issue #135). The file contents are
  # compared in escaped form, exactly as they are written by #save.
  def has_new_entry?(file)
    existing = existing_entries(file)
    Reline::HISTORY.any? { |entry| !existing.include?(escape(entry)) }
  end

  # The entries this session id already has persisted (one escaped line
  # each), or an empty list when the file does not exist yet.
  def existing_entries(file)
    return [] unless File.file?(file)

    File.foreach(file).map { |line| line.chomp }
          .reject(&:empty?)
  end

  # The per-session file for the current id, or the legacy shared file
  # when no session has been bound yet (e.g. --list-sessions at startup).
  def resolve_file
    base = File.join(@workdir, Harness::HARNESS_DIR)
    if @current_id
      File.join(base, 'sessions', @current_id, LEGACY_FILENAME)
    else
      File.join(base, LEGACY_FILENAME)
    end
  end

  # Read path: the per-session file, falling back to the legacy shared
  # file when the session has no file of its own yet (so pre-#119
  # entries are not lost on the first resume of an old session). Saves
  # always go to the per-session file, keeping sessions isolated.
  def read_file
    per_session = @history_file
    if @current_id && !File.exist?(per_session)
      legacy = File.join(@workdir, Harness::HARNESS_DIR, LEGACY_FILENAME)
      return legacy if File.exist?(legacy)
    end

    per_session
  end

  # Encode a (possibly multiline) history entry as a single line.
  # Backslashes are escaped first, then newlines and carriage returns are
  # replaced by their two-character escape sequences.
  def escape(text)
    text.gsub('\\', '\\\\').gsub("\n", '\\n').gsub("\r", '\\r')
  end

  # Decode a single history line back into the original entry.
  # Single-pass scan so that e.g. a literal `\n` in the original entry
  # (escaped as `\\n`) is not mistaken for a newline. Only the escape
  # sequences produced by escape are interpreted; any other
  # `\X` sequence is kept as-is (backslash preserved).
  def unescape(line)
    line.gsub(/\\(.)/) do |m|
      case m[1]
      when 'n' then "\n"
      when 'r' then "\r"
      when '\\' then '\\'
      else m # unknown escape - keep the backslash and the character
      end
    end
  end
end
