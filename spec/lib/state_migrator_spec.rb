# frozen_string_literal: true

require 'tmpdir'
require 'rspec/mocks'
require 'fileutils'
require 'spec_helper'
require 'state_migrator'

RSpec.describe StateMigrator do
  let(:workdir) { Dir.mktmpdir('migrator-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  describe '#migrate - sessions and history' do
    it 'moves .sessions/ into .harness/sessions/' do
      src = File.join(workdir, '.sessions')
      FileUtils.mkdir_p(src)
      File.write(File.join(src, 'a.json'), '{}')

      described_class.run(workdir, '.harness')

      expect(File.file?(File.join(workdir, '.harness', 'sessions', 'a.json'))).to be true
      expect(File.directory?(src)).to be false
    end

    it 'moves .harness_history into .harness/harness_history' do
      File.write(File.join(workdir, '.harness_history'), "prompt\n")

      described_class.run(workdir, '.harness')

      expect(File.file?(File.join(workdir, '.harness', 'harness_history'))).to be true
      expect(File.exist?(File.join(workdir, '.harness_history'))).to be false
    end

    it 'is a no-op when there is nothing to migrate' do
      described_class.run(workdir, '.harness')

      expect(File.directory?(File.join(workdir, '.harness'))).to be false
    end

    it 'does not move the legacy harness.log (issue #120)' do
      File.write(File.join(workdir, 'harness.log'), "old\n")

      described_class.run(workdir, '.harness')

      expect(File.file?(File.join(workdir, 'harness.log'))).to be true
      expect(File.directory?(File.join(workdir, '.harness'))).to be false
    end
  end

  describe '#migrate - error handling (issue #120)' do
    def stub_mkdir_p_failure!
      allow(FileUtils).to receive(:mkdir_p)
        .and_raise(Errno::EACCES, 'permission denied')
    end

    it 'reports a failed step on stderr without raising' do
      FileUtils.mkdir_p(File.join(workdir, '.sessions'))
      stub_mkdir_p_failure!

      expect { described_class.run(workdir, '.harness') }
        .not_to raise_error
    end

    it 'a failing step does not block the remaining steps' do
      FileUtils.mkdir_p(File.join(workdir, '.sessions'))
      File.write(File.join(workdir, '.harness_history'), "prompt\n")
      stub_mkdir_p_failure!

      described_class.run(workdir, '.harness')

      # Both steps fail on mkdir_p and are reported; nothing is moved.
      expect(File.directory?(File.join(workdir, '.sessions'))).to be true
      expect(File.exist?(File.join(workdir, '.harness_history'))).to be true
    end

    it 'reports the failure on stderr (issue #120)' do
      FileUtils.mkdir_p(File.join(workdir, '.sessions'))
      stub_mkdir_p_failure!

      real_stderr = $stderr
      stderr      = ''
      $stderr = StringIO.new
      begin
        described_class.run(workdir, '.harness')
      ensure
        stderr      = $stderr.string
        $stderr = real_stderr
      end
      expect(stderr).to include('[state-migrator]')
      expect(stderr).to include('sessions migration failed')
    end
  end
end
