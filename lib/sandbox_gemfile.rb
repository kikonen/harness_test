# frozen_string_literal: true

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
    # gems. The harness seeded these; edit freely (bundle add/lock updates the lock).
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

  # Create the directory and drop the starter ONLY if no Gemfile is there yet, so
  # a model-managed Gemfile is never overwritten. No bundler/network: this only
  # writes a text scaffold; the model runs `bundle install` through run.command
  # (consent-gated) when it first uses the sandbox.
  def ensure_starter!
    return gemfile_path if exist?

    FileUtils.mkdir_p(dir)
    File.write(gemfile_path, STARTER_GEMFILE)
    gemfile_path
  end
end
