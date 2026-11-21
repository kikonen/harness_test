# frozen_string_literal: true

require "logger"
require "fileutils"

# -- SessionLogger --------------------------------------------------------
#
# The per-session log file's logger: its file plus the fixed line format. The
# log path is keyed by the session id, which the system's owner (CLI) resolves
# before construction, so the owner can build a finished logger here and inject
# it into the Harness instead of the turn engine minting its own (#286). The
# system/world half of the harness builds it, not the LLM loop.
class SessionLogger
  # issue #548: ONE Logger object per log path, process-wide. Two Logger objects
  # opened on the same path share Logger's class-level @log_mutex (so lines never
  # interleave) yet LOSE writes because each keeps its own file position (~10% of
  # 400 concurrent writes, analysis/548). A per-job Harness built with an injected
  # session id but no injected logger would open a second writer on the foreground's
  # path; memoizing the path makes every consumer read the SAME object.
  @loggers        = {}
  @loggers_mutex  = Mutex.new

  def self.build(log_path)
    @loggers_mutex.synchronize do
      @loggers[log_path] ||= begin
        FileUtils.mkdir_p(File.dirname(log_path))
        logger = Logger.new(log_path)
        logger.formatter = proc { |severity, datetime, _progname, msg|
          "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
        }
        logger
      end
    end
  end
end
