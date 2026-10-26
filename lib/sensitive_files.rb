# frozen_string_literal: true

# The paths a grant can NEVER cover, the shape of the regions where a sensitive
# NAME does not count, and the owner's own space - a path a human grant CAN cover
# but a posture never may (an auto-grant must not quietly remove the veto the user
# kept there). Rationale and measurements:
# doc/sensitive_paths_design.md and doc/skills_design.md.
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

  # The project's own skills directory, relative to the working directory. A skill
  # is repo content the owner chose to keep, so this subtree of .harness/ is
  # grantable - the exemption lifts the .harness component only, never a .env* name.
  SKILLS_DIR = ".harness/skills"

  # The owner's space, workdir-relative: top-level local/ and everything under it.
  # NOT a sensitive dir - a human grant on it is legal, and today it is the human's
  # dialog that protects it. The list exists so a posture that auto-grants the rest
  # of the working directory leaves local/ asking (issue #274).
  OWNER_DIR = "local"

  def self.sensitive?(path)
    env_named?(path) || state_dir?(path)
  end

  def self.env_named?(path)
    name = File.basename(path.to_s)
    SENSITIVE_PATTERNS.any? { |pat| File.fnmatch?(pat, name, File::FNM_DOTMATCH) }
  end

  def self.state_dir?(path)
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

  # True when a workdir-relative path IS the skills directory or lies inside it. An
  # exact prefix test on the RELATIVE path (like the scratch zone test), so
  # relative_path has already resolved .harness/skills/../sessions out of the zone.
  def self.skills_zone?(rel_path)
    !rel_path.nil? && (rel_path == SKILLS_DIR || rel_path.start_with?("#{SKILLS_DIR}/"))
  end

  # True when a workdir-relative path IS the owner's space or lies inside it. Same
  # exact-prefix shape as the zones above, so a resolved path that escaped local/
  # (local/../analysis) does not match.
  def self.owner_space?(rel_path)
    !rel_path.nil? && (rel_path == OWNER_DIR || rel_path.start_with?("#{OWNER_DIR}/"))
  end
end
