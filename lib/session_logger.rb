# frozen_string_literal: true

require "logger"
require "fileutils"

# -- SessionLogger --------------------------------------------------------
#
# The per-session log file's logger: its file plus the fixed line format. The
# log path is keyed by the session id, which the run's owner (CLI) resolves
# before construction, so the owner can build a finished logger here and inject
# it into the Harness instead of the turn engine minting its own (#286). The
# run/world half of the harness builds it, not the LLM loop.
class SessionLogger
  def self.build(log_path)
    FileUtils.mkdir_p(File.dirname(log_path))
    logger = Logger.new(log_path)
    logger.formatter = proc { |severity, datetime, _progname, msg|
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
    }
    logger
  end
end
