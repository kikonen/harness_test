# frozen_string_literal: true

require "bundler"
require "fileutils"
require_relative "sensitive_files"

# The blessed location for project-specific Ruby scripts and their gems
# (issue #340). Rationale and the measured load-path trap: doc/sandbox_gemfile_design.md.
class SandboxGemfile
  DIR = SensitiveFiles::SANDBOX_DIR
  GEMFILE_NAME = "Gemfile"

  # The starter lives in the repo (config/sandbox_gemfile.example.rb), not
  # embedded here: it is the single source of what a fresh sandbox holds, so its
  # gem list is editable like config/config.example.yml's is.
  STARTER_TEMPLATE_FILE = File.expand_path(
    "../config/sandbox_gemfile.example.rb", __dir__)
  # A gem name as the bare `gem "name"` form bundler writes it; a version
  # constraint after the name is deliberately NOT captured, so a model's own
  # constraint counts as declaring that gem.
  GEM_DECLARATION = /^\s*gem\s+"([a-z0-9_\-]+)"/

  def initialize(workdir)
    @workdir = workdir
  end

  # Seed the starter and keep the default list as a floor, logging each outcome
  # (nil logger logs nothing). The harness calls this once at construction
  # because the model's file tools cannot write .harness/.
  def setup!(logger = nil)
    case ensure_starter!
    when :seeded_locked
      logger&.info "ruby sandbox seeded and locked offline"
    when :seeded_unlocked
      logger&.info "ruby sandbox seeded but the offline lock failed " \
        "(a starter gem is absent on this box) - bundle install it"
    when :seeded_unreadable
      logger&.warn "ruby sandbox NOT seeded - the default Gemfile " \
        "#{STARTER_TEMPLATE_FILE} is unreadable"
    end
    case ensure_default_gems!
    when :resynced_locked
      logger&.info "ruby sandbox resynced with the default gems and re-locked"
    when :resynced_unlocked
      logger&.info "ruby sandbox resynced with the default gems but the offline " \
        "lock failed - bundle install it"
    end
    self
  end

  def dir
    File.join(@workdir, DIR)
  end

  def gemfile_path
    File.join(dir, GEMFILE_NAME)
  end

  # The workdir-relative path the model types (run.command runs in the workdir).
  def relative_gemfile_path
    File.join(DIR, GEMFILE_NAME)
  end

  def exist?
    File.file?(gemfile_path)
  end

  # The DEFAULT gem list (the template's names, in template order). Public
  # because it is a floor worth stating: what a sandbox is supposed to hold.
  def default_gem_names
    Array(read_template&.scan(GEM_DECLARATION)).flatten.uniq
  end

  def declared_gem_names
    return [] unless exist?

    Array(File.read(gemfile_path).scan(GEM_DECLARATION)).flatten.uniq
  end

  # Seed the starter ONLY when no Gemfile is there yet, so a model-managed one is
  # never overwritten, then try to make it a working bundle by locking it offline.
  # Returns :seeded_locked, :seeded_unlocked or :seeded_unreadable so the caller
  # can say whether the seed is ready to run. The lock attempt runs only on a
  # fresh seed - every later launch goes to #ensure_default_gems!.
  def ensure_starter!
    return :existing if exist?

    FileUtils.mkdir_p(dir)
    template = read_template
    return :seeded_unreadable if template.nil?

    File.write(gemfile_path, template)
    lock_seeded? ? :seeded_locked : :seeded_unlocked
  end

  # The default gem list is a FLOOR, not a starter-only snapshot: a sandbox the
  # model rewrote (or a seed from an older default) must not lose a gem the
  # default declares, or a script that needs it fails mid-run with a bare
  # LoadError. Appends only what is missing, as a bare declaration so a version
  # constraint the model wrote for that gem is never rewritten, then re-locks.
  # nil means nothing was missing - the common case, and it runs no bundler.
  def ensure_default_gems!
    missing = default_gem_names - declared_gem_names
    return nil if missing.empty?

    File.open(gemfile_path, "a") do |f|
      f.write("\n") unless File.read(gemfile_path).end_with?("\n")
      missing.each { |name| f.write(%(gem "#{name}"\n)) }
    end
    lock_seeded? ? :resynced_locked : :resynced_unlocked
  end

  # Make the seeded Gemfile a real, resolvable bundle WITHOUT the network:
  # `bundle lock --local` writes a Gemfile.lock only when every declared gem is
  # already on this box, and a missing gem (or no bundler) leaves NO partial lock
  # (measured). That is why this never installs: an absent gem is the model's
  # consent-gated `bundle install`, not a harness network call. A bundler problem
  # must never crash harness startup, so failures and raises collapse to false.
  def lock_seeded?
    Bundler.with_unbundled_env do
      system(
        { "BUNDLE_GEMFILE" => gemfile_path },
        "bundle",
        "lock",
        "--local",
        out: File::NULL,
        err: File::NULL) ? true : false
    end
  rescue StandardError
    false
  end

  private

  def read_template
    return nil unless File.file?(STARTER_TEMPLATE_FILE)

    File.read(STARTER_TEMPLATE_FILE)
  end
end
