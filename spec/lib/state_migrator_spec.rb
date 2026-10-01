# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'spec_helper'
require 'state_migrator'

RSpec.describe StateMigrator do
  let(:workdir) { Dir.mktmpdir('migrator-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  describe '.run / #migrate - legacy log migration (issue #113)' do
    def legacy_log
      File.join(workdir, 'harness.log')
    end

    it 'moves the legacy harness.log into the session directory' do
      File.write(legacy_log, "old\n")

      described_class.run(workdir, Harness::HARNESS_DIR, 'sess-123')

      dest = File.join(workdir, '.harness', 'sessions', 'sess-123', 'harness.log')
      expect(File.file?(dest)).to be true
      expect(File.read(dest)).to eq("old\n")
      expect(File.exist?(legacy_log)).to be false
    end

    it 'skips the log migration when no session id is given' do
      File.write(legacy_log, "old\n")

      described_class.run(workdir, Harness::HARNESS_DIR)

      expect(File.file?(legacy_log)).to be true
      expect(File.directory?(File.join(workdir, '.harness'))).to be false
    end

    it 'is a no-op when the destination already exists' do
      File.write(legacy_log, "old\n")
      dest_dir = File.join(workdir, '.harness', 'sessions', 'sess-123')
      FileUtils.mkdir_p(dest_dir)
      File.write(File.join(dest_dir, 'harness.log'), "new\n")

      described_class.run(workdir, Harness::HARNESS_DIR, 'sess-123')

      expect(File.read(File.join(dest_dir, 'harness.log'))).to eq("new\n")
      expect(File.file?(legacy_log)).to be true
    end

    it 'does nothing when there is no legacy log' do
      described_class.run(workdir, Harness::HARNESS_DIR, 'sess-123')

      expect(File.directory?(File.join(workdir, '.harness'))).to be false
    end
  end

  describe '#migrate - sessions and history (regression)' do
    it 'moves .sessions/ into .harness/sessions/' do
      src = File.join(workdir, '.sessions')
      FileUtils.mkdir_p(src)
      File.write(File.join(src, 'a.json'), '{}')

      described_class.run(workdir, Harness::HARNESS_DIR, 'sess-123')

      expect(File.file?(File.join(workdir, '.harness', 'sessions', 'a.json'))).to be true
      expect(File.directory?(src)).to be false
    end

    it 'moves .harness_history into .harness/harness_history' do
      File.write(File.join(workdir, '.harness_history'), "prompt\n")

      described_class.run(workdir, Harness::HARNESS_DIR, 'sess-123')

      expect(File.file?(File.join(workdir, '.harness', 'harness_history'))).to be true
      expect(File.exist?(File.join(workdir, '.harness_history'))).to be false
    end
  end
end
