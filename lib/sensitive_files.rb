# frozen_string_literal: true

# The paths a grant can NEVER cover, and the shape of the one region where a
# sensitive NAME does not count. Rationale and measurements:
# doc/sensitive_paths_design.md.
module SensitiveFiles
  # Basename patterns: config/.env.production is blocked too, not just a bare .env.
  SENSITIVE_PATTERNS = [
    ".env*"
  ].freeze

  # Directory names matched against EVERY component, so vendor/.git/HEAD is blocked.
  SENSITIVE_DIRS = [
    ".git",
    ".harness"
  ].freeze

  # Scratch zones (tmp/scratch/<n>/, tmp/keep/<n>/) matched against the path
  # RELATIVE to the working directory. <n> is any zone name, not just a number.
  SCRATCH_ZONE = %r{\Atmp/(?:scratch|keep)/[^/.][^/]*/}

  def self.sensitive?(path)
    name = File.basename(path.to_s)
    return true if SENSITIVE_PATTERNS.any? { |pat| File.fnmatch?(pat, name, File::FNM_DOTMATCH) }

    # File.expand_path normalizes separators to "/" on every platform, so
    # splitting on "/" also works for a Windows path.
    components = File.expand_path(path.to_s).split("/")
    SENSITIVE_DIRS.any? { |dir| components.include?(dir) }
  end

  # True when a path lies inside a per-issue scratch zone: its nested
  # .git/.harness/.env* is a disposable clone the harness created, not this
  # project's own state. rel_path is nil for a path outside the working dir.
  def self.scratch_zone?(rel_path)
    !rel_path.nil? && SCRATCH_ZONE.match?(rel_path)
  end
end
