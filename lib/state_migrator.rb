# frozen_string_literal: true

require 'fileutils'

# One-time migration of harness state that used to live scattered in the
# working directory into the .harness directory:
#   .sessions/          -> .harness/sessions/
#   .harness_history    -> .harness/harness_history
#   harness.log         -> .harness/sessions/<session-id>/harness.log (issue #113)
#
# Existing files are moved (not copied) and only if the destination does
# not exist yet. Best-effort: any failure is silently ignored.
class StateMigrator
  def self.run(workdir, harness_dir_name = Harness::HARNESS_DIR, session_id = nil)
    new(workdir, harness_dir_name, session_id).migrate
  end

  def initialize(workdir, harness_dir_name, session_id = nil)
    @workdir       = workdir
    @harness_dir   = File.join(workdir, harness_dir_name)
    @session_id    = session_id
  end

  def migrate
    migrate_sessions
    migrate_history
    migrate_log
  rescue StandardError
    # Migration is best-effort - never block the harness on it.
  end

  private

  def migrate_sessions
    old = File.join(@workdir, '.sessions')
    new = File.join(@harness_dir, 'sessions')
    if File.directory?(old) && !File.directory?(new)
      FileUtils.mkdir_p(@harness_dir)
      FileUtils.mv(old, new)
    end
  end

  def migrate_history
    old = File.join(@workdir, '.harness_history')
    new = File.join(@harness_dir, 'harness_history')
    if File.file?(old) && !File.exist?(new)
      FileUtils.mkdir_p(@harness_dir)
      FileUtils.mv(old, new)
    end
  end

  def migrate_log
    old = File.join(@workdir, 'harness.log')
    # issue #113: logs are per-session now; the legacy shared log belongs to
    # the session that is running the migration. When no session id is
    # given (e.g. specs) the migration is skipped.
    return unless @session_id
    new = File.join(@harness_dir, 'sessions', @session_id, 'harness.log')
    if File.file?(old) && !File.exist?(new)
      # The target directory must exist: mv(1)/rename does not create it.
      FileUtils.mkdir_p(File.dirname(new))
      FileUtils.mv(old, new)
    end
  end
end
