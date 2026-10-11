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

      # issue #207: the legacy <id>.json is also moved INSIDE the session
      # dir as session.json.
      expect(File.file?(File.join(workdir, '.harness', 'sessions', 'a', 'session.json')))
        .to be true
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

  describe '#migrate - session JSON into the session dir (issue #207)' do
    def seed_legacy_json(sid)
      sessions = File.join(workdir, '.harness', 'sessions')
      FileUtils.mkdir_p(sessions)
      File.write(File.join(sessions, "#{sid}.json"), '{}')
    end

    it 'moves <id>.json into <id>/session.json' do
      seed_legacy_json('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')

      described_class.run(workdir, '.harness')

      target = File.join(workdir, '.harness/sessions', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'session.json')
      expect(File.file?(target)).to be true
    end

    it 'never overwrites an existing destination' do
      seed_legacy_json('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
      existing = File.join(workdir, '.harness/sessions',
                           'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'session.json')
      FileUtils.mkdir_p(File.dirname(existing))
      File.write(existing, '{"kept":true}')

      described_class.run(workdir, '.harness')

      expect(File.read(existing)).to eq('{"kept":true}')
    end

    it 'is a no-op when there are no legacy session files' do
      FileUtils.mkdir_p(File.join(workdir, '.harness', 'sessions'))

      described_class.run(workdir, '.harness')

      expect(Dir.children(File.join(workdir, '.harness/sessions'))).to be_empty
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
