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
  def save
    file = @history_file
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
