# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'job_registry'
require 'commands/save_command'

RSpec.describe Commands::SaveCommand do
  # The harness double answers active_profile_name like the real SessionManager
  # does, so a spec can prove resume_cli_string leaves the model OUT of the
  # command line even when a model is live.
  def harness_with(id, path, active_profile_id: 'qwen3:8b')
    sm = Object.new
    sm.define_singleton_method(:save_session) { id }
    sm.define_singleton_method(:session_file_path) { |session_id| path % session_id }
    sm.define_singleton_method(:active_profile_name) { active_profile_id }
    h = Object.new
    h.define_singleton_method(:session_manager) { sm }
    sess = Object.new
    sess.define_singleton_method(:session_id) { id }
    h.define_singleton_method(:session) { sess }
    h
  end

  def run_command(file_list, id: 'abc123', path: '.harness/sessions/%s/session.json')
    stdout = StringIO.new
    registry = JobRegistry.new
    registry.add_job(kind: :main, harness: harness_with(id, path))
    saver = Object.new
    saver.define_singleton_method(:save_run) { |run_id| run_id }
    described_class.new(registry:, file_list: file_list,
                        ui: UI::Console.new(stdout: stdout),
                        system_saver: saver).handle('')
    stdout.string
  end

  it 'reports the saved id with the file path the session lives at' do
    Dir.mktmpdir do |dir|
      out = run_command(FileList.new([], workdir: dir))

      expect(out).to include('Session saved as abc123')
      expect(out).to include('.harness/sessions/abc123/session.json')
    end
  end

  it 'prints the startup --resume command line that resumes the saved id' do
    Dir.mktmpdir do |dir|
      expect(run_command(FileList.new([], workdir: dir))).to include('--resume abc123')
    end
  end

  describe 'resume_cli_string' do
    # No -m on purpose: a resumed run restores the session's OWN profile
    # (SessionManager#restore_active_profile), so naming a model here could only
    # contradict it. bin/harness is the launcher the user actually types.
    it 'builds the command line as bin/harness --resume <id>, with no -m' do
      Dir.mktmpdir do |_dir|
        registry = JobRegistry.new
        registry.add_job(kind: :main, harness: harness_with('abc123', 'x'))
        cli = described_class.new(registry:,
                                  file_list: FileList.new([], workdir: Dir.pwd),
                                  ui: UI::Console.new(stdout: StringIO.new))
          .resume_cli_string('abc123')

        expect(cli).to start_with('bin/harness')
        expect(cli).not_to include('ruby harness.rb')
        expect(cli).not_to include('-m ')
        expect(cli).to include('--resume abc123')
        # No -d: the workdir IS Dir.pwd, so the plain command line already
        # resumes in the right place.
        expect(cli).not_to include('-d ')
      end
    end

    # The old behaviour was to name the model the run SWITCHED to. The session
    # carries that itself, so the printed line must not name any model.
    it 'names no model even when the run switched to one' do
      Dir.mktmpdir do |_dir|
        registry = JobRegistry.new
        registry.add_job(kind: :main, harness: harness_with('abc123', 'x', active_profile_id: 'big'))
        cli = described_class.new(registry:,
                                  file_list: FileList.new([], workdir: Dir.pwd),
                                  ui: UI::Console.new(stdout: StringIO.new))
          .resume_cli_string('abc123')

        expect(cli).to eq('bin/harness --resume abc123')
      end
    end

    it 'adds -d <workdir> only when the workdir differs from the current directory' do
      Dir.mktmpdir do |dir|
        registry = JobRegistry.new
        registry.add_job(kind: :main, harness: harness_with('abc123', 'x'))
        cli = described_class.new(registry:,
                                  file_list: FileList.new([], workdir: dir),
                                  ui: UI::Console.new(stdout: StringIO.new))
          .resume_cli_string('abc123')

        expect(cli).to include("-d #{dir}")
      end
    end
  end
end
