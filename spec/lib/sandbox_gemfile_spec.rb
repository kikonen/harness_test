# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'sandbox_gemfile'

RSpec.describe SandboxGemfile do
  def sandbox_in(dir)
    described_class.new(dir)
  end

  # A Gemfile listing ONLY a gem guaranteed present on every box, so a real
  # offline `bundle lock --local` must succeed without touching the network.
  def seed_present_gem(sandbox)
    FileUtils.mkdir_p(sandbox.dir)
    File.write(sandbox.gemfile_path, %(source "https://rubygems.org"\ngem "json"\n))
  end

  def seed_absent_gem(sandbox)
    FileUtils.mkdir_p(sandbox.dir)
    File.write(
      sandbox.gemfile_path,
      %(source "https://rubygems.org"\ngem "definitely_absent_gem_340"\n)
    )
  end

  describe 'the paths' do
    it 'points at .harness/sandbox/Gemfile under the working directory' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        expect(s.dir).to eq(File.join(dir, '.harness', 'sandbox'))
        expect(s.gemfile_path).to eq(File.join(dir, '.harness', 'sandbox', 'Gemfile'))
      end
    end

    it 'exposes the workdir-relative path the model types' do
      Dir.mktmpdir do |dir|
        expect(sandbox_in(dir).relative_gemfile_path).to eq('.harness/sandbox/Gemfile')
      end
    end
  end

  describe 'the starter' do
    # bundle exec isolates the load path, so an empty starter would break even
    # csv/rexml/logger (doc/sandbox_gemfile_design.md); the seed must list gems.
    it 'is not empty and declares the common stdlib-adjacent gems' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        s.ensure_starter!
        text = File.read(s.gemfile_path)

        expect(text).to include('source "https://rubygems.org"')
        %w[csv json rexml logger racc base64 fiddle reline].each do |name|
          expect(text).to match(/gem "#{name}"/)
        end
      end
    end

    # The starter lives in the repo (config/), so its gem list is editable like
    # config/config.example.yml's is - nothing is embedded in the source.
    it 'is a copy of the repo template file' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        s.ensure_starter!

        expect(File.read(s.gemfile_path)).to eq(File.read(described_class::STARTER_TEMPLATE_FILE))
      end
    end

    it 'writes the starter and creates the directory' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        expect(s.exist?).to be false

        s.ensure_starter!
        expect(s.exist?).to be true
        expect(File.directory?(s.dir)).to be true
      end
    end
  end

  describe '#ensure_starter!' do
    it 'is idempotent - a second call leaves the file untouched' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        s.ensure_starter!
        first = File.read(s.gemfile_path)

        expect(s.ensure_starter!).to eq(:existing)
        expect(File.read(s.gemfile_path)).to eq(first)
      end
    end

    # The harness seeds it but the model manages it: an existing (model-edited)
    # Gemfile is NEVER clobbered, even when it is nothing like the starter.
    it 'never overwrites a model-managed Gemfile' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(sandbox_in(dir).dir)
        managed = "# frozen_string_literal: true\n\ngem 'nokogiri'\n"
        File.write(sandbox_in(dir).gemfile_path, managed)

        expect(sandbox_in(dir).ensure_starter!).to eq(:existing)
        expect(File.read(sandbox_in(dir).gemfile_path)).to eq(managed)
      end
    end
  end

  describe '#ensure_default_gems! (the default list as a floor)' do
    # A sandbox the model rewrote down to one gem must get the starter's gems back,
    # or a script that needs one fails mid-run with a bare LoadError.
    it 'appends the default gems a rewritten sandbox lost' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        FileUtils.mkdir_p(s.dir)
        File.write(s.gemfile_path, %(source "https://rubygems.org"\ngem "json"\n))
        allow(s).to receive(:lock_seeded?).and_return(true)

        expect(s.ensure_default_gems!).to eq(:resynced_locked)
        text = File.read(s.gemfile_path)
        expect(text).to include('gem "json"')
        (s.default_gem_names - ['json']).each { |name| expect(text).to include(%(gem "#{name}")) }
      end
    end

    # The common case: nothing is missing, so the file is not touched and no
    # bundler runs.
    it 'is a no-op (nil, no bundler) when every default gem is already declared' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        s.ensure_starter!
        before = File.read(s.gemfile_path)
        expect(s).not_to receive(:lock_seeded?)

        expect(s.ensure_default_gems!).to be_nil
        expect(File.read(s.gemfile_path)).to eq(before)
      end
    end

    # The model's own constraint for a gem must survive the resync: a gem named
    # there is never re-added, and never rewritten.
    it 'keeps a version constraint the model wrote for a default gem' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        FileUtils.mkdir_p(s.dir)
        File.write(
          s.gemfile_path,
          %(source "https://rubygems.org"\ngem "logger", ">= 1.7"\ngem "json"\n)
        )
        allow(s).to receive(:lock_seeded?).and_return(true)

        s.ensure_default_gems!
        text = File.read(s.gemfile_path)
        expect(text).to include('gem "logger", ">= 1.7"')
        expect(text.scan(/gem "logger"/).size).to eq(1)
      end
    end

    # A missing lock must not be treated as a gem problem - and a resync that
    # could not re-lock says so rather than leaving a silently unresolvable bundle.
    it 'reports :resynced_unlocked when the re-lock failed' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        FileUtils.mkdir_p(s.dir)
        File.write(s.gemfile_path, %(source "https://rubygems.org"\ngem "json"\n))
        allow(s).to receive(:lock_seeded?).and_return(false)

        expect(s.ensure_default_gems!).to eq(:resynced_unlocked)
      end
    end
  end

  describe '#lock_seeded? (the offline bundle lock)' do
    # A guaranteed-present gem: the offline lock writes a real Gemfile.lock
    # naming it, without the network.
    it 'locks a seeded Gemfile whose gems are all on this box' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        seed_present_gem(s)

        expect(s.lock_seeded?).to be true
        lock = File.join(s.dir, 'Gemfile.lock')
        expect(File.file?(lock)).to be true
        expect(File.read(lock)).to include('json')
      end
    end

    # A gem not on the box: the lock is NOT written (no partial lock), so the
    # seed stays a manifest the model completes with its own bundle install.
    it 'leaves no lock when a gem is absent, and does not raise' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        seed_absent_gem(s)

        expect(s.lock_seeded?).to be false
        expect(File.exist?(File.join(s.dir, 'Gemfile.lock'))).to be false
      end
    end

    # ensure_starter! reports which of the two happened, so Harness can log it.
    it 'ensure_starter! returns :seeded_locked when the starter could be locked' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        allow(s).to receive(:lock_seeded?).and_return(true)

        expect(s.ensure_starter!).to eq(:seeded_locked)
      end
    end

    it 'ensure_starter! returns :seeded_unlocked when the lock failed' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        allow(s).to receive(:lock_seeded?).and_return(false)

        expect(s.ensure_starter!).to eq(:seeded_unlocked)
      end
    end

    # A bundler problem must never crash harness startup.
    it 'collapses a bundler raise to false' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        allow(Bundler).to receive(:with_unbundled_env)
          .and_raise(StandardError, "bundler exploded")

        expect(s.lock_seeded?).to be false
      end
    end
  end
end
