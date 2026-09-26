# frozen_string_literal: true

require 'fileutils'
require 'reline'

# Manages persistence of Reline's command history to a file inside the
# harness working directory. One entry per line, with backslashes and
# newlines escaped so multiline entries survive the round trip.
class HistoryManager
  # Default history file location (relative to workdir).
  DEFAULT_FILENAME = 'harness_history'

  def initialize(workdir)
    @history_file = File.join(workdir, Harness::HARNESS_DIR, DEFAULT_FILENAME)
  end

  attr_reader :history_file

  # Load persisted history into Reline (best-effort).
  def load
    return unless File.exist?(@history_file)

    Reline::HISTORY.clear
    File.foreach(@history_file) do |line|
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
    FileUtils.mkdir_p(File.dirname(@history_file))
    File.open(@history_file, 'w') do |f|
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
