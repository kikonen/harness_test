# frozen_string_literal: true

require "bundler"
require "fileutils"

# The blessed location for project-specific Ruby scripts and their gems
# (issue #340). Rationale and the measured load-path trap: doc/sandbox_gemfile_design.md.
class SandboxGemfile
  DIR = ".harness/sandbox"
  GEMFILE_NAME = "Gemfile"

  # A starter that is NOT empty on purpose: `bundle exec` isolates the load path
  # to what the Gemfile declares, so an empty one silently breaks even csv/rexml/
  # logger/racc/base64 (measured - only true-default json survives). These are the
  # common format/stdlib-adjacent gems; anything else the model adds on demand.
  STARTER_GEMFILE = <<~'GEMFILE'
    # frozen_string_literal: true

    # Project Ruby sandbox (issue #340). Run scripts with:
    #   BUNDLE_GEMFILE=.harness/sandbox/Gemfile bundle exec ruby script.rb
    # Add a gem you need with:  BUNDLE_GEMFILE=.harness/sandbox/Gemfile bundle install
    # This pins versions so a script's result does not vary with the box's ambient
    # gems. The harness seeded these and tried to write a lock for them offline;
    # if one is missing (gem not on this box yet), run bundle install. Edit freely.
    source "https://rubygems.org"

    gem "csv"
    gem "json"
    gem "rexml"
    gem "logger"
    gem "racc"
    gem "base64"
  GEMFILE

  def initialize(workdir)
    @workdir = workdir
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

  # Seed the starter ONLY when no Gemfile is there yet, so a model-managed one is
  # never overwritten, then try to make it a working bundle by locking it offline.
  # Returns :existing (nothing touched), :seeded_locked or :seeded_unlocked so the
  # caller can say whether the seed is ready to run. The lock attempt runs only on
  # a FRESH seed - every later launch hits the early return and runs no bundler.
  def ensure_starter!
    return :existing if exist?

    FileUtils.mkdir_p(dir)
    File.write(gemfile_path, STARTER_GEMFILE)
    lock_seeded? ? :seeded_locked : :seeded_unlocked
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
end
