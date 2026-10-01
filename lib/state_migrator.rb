# frozen_string_literal: true

require 'fileutils'

# One-time migration of harness state that used to live scattered in the
# working directory into the .harness directory:
#   .sessions/          -> .harness/sessions/
#   .harness_history    -> .harness/harness_history
#
# The legacy shared harness.log is NOT migrated (issue #120): logs are
# per-session now (issue #113), so the old file has no session to belong
# to, and moving it can fail outright on Windows when another process
# in the same workdir still holds the file open. It is simply left in
# place for the user to inspect or delete.
#
# Existing files are moved (not copied) and only if the destination does
# not exist yet. Best-effort: a failure in one step never blocks the
# others, but every failure is reported on stderr (issue #120 - it used
# to fail completely silently).
class StateMigrator
  def self.run(workdir, harness_dir_name = Harness::HARNESS_DIR)
    new(workdir, harness_dir_name).migrate
  end

  def initialize(workdir, harness_dir_name)
    @workdir     = workdir
    @harness_dir = File.join(workdir, harness_dir_name)
  end

  def migrate
    migrate_step(:sessions) { migrate_sessions }
    migrate_step(:history)  { migrate_history }
  end

  private

  # Runs one migration step best-effort: any failure is reported on
  # stderr (issue #120) but never propagated, so the harness itself is
  # never blocked by a migration problem.
  def migrate_step(step)
    yield
  rescue StandardError => e
    warn "  [state-migrator] #{step} migration failed: #{e.class}: #{e.message}"
  end

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
end
