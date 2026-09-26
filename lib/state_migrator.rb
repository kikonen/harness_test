# frozen_string_literal: true

require 'fileutils'

# One-time migration of harness state that used to live scattered in the
# working directory into the .harness directory:
#   .sessions/          -> .harness/sessions/
#   .harness_history    -> .harness/harness_history
#   harness.log         -> .harness/harness.log
#
# Existing files are moved (not copied) and only if the destination does
# not exist yet. Best-effort: any failure is silently ignored.
class StateMigrator
  def self.run(workdir, harness_dir_name = Harness::HARNESS_DIR)
    new(workdir, harness_dir_name).migrate
  end

  def initialize(workdir, harness_dir_name)
    @workdir       = workdir
    @harness_dir   = File.join(workdir, harness_dir_name)
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
    new = File.join(@harness_dir, 'harness.log')
    if File.file?(old) && !File.exist?(new)
      FileUtils.mkdir_p(@harness_dir)
      FileUtils.mv(old, new)
    end
  end
end
