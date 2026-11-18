# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'commands/save_command'

RSpec.describe Commands::SaveCommand do
  # resume_cli_string names the live active model PROFILE (-m names a profile,
  # not a wire id), so the harness double answers active_model_name like the real
  # SessionManager does.
  def harness_with(id, path, active_model: 'qwen3:8b')
    sm = Object.new
    sm.define_singleton_method(:save_session) { id }
    sm.define_singleton_method(:session_file_path) { |session_id| path % session_id }
    sm.define_singleton_method(:active_model_name) { active_model }
    h = Object.new
    h.define_singleton_method(:session_manager) { sm }
    h
  end

  def run_command(file_list, id: 'abc123', path: '.harness/sessions/%s/session.json')
    stdout = StringIO.new
    described_class.new(harness: harness_with(id, path), file_list: file_list,
                        ui: UI::Console.new(stdout: stdout)).handle('')
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
    it 'builds the command line with the active model and --resume <id>' do
      Dir.mktmpdir do |_dir|
        cli = described_class.new(harness: harness_with('abc123', 'x'),
                                  file_list: FileList.new([], workdir: Dir.pwd),
                                  ui: UI::Console.new(stdout: StringIO.new))
          .resume_cli_string('abc123')

        expect(cli).to include('ruby harness.rb')
        expect(cli).to include('-m qwen3:8b')
        expect(cli).to include('--resume abc123')
        # No -d: the workdir IS Dir.pwd, so the plain command line already
        # resumes in the right place.
        expect(cli).not_to include('-d ')
      end
    end

    it 'names the model the run switched to, not the original -m' do
      Dir.mktmpdir do |_dir|
        cli = described_class.new(harness: harness_with('abc123', 'x', active_model: 'big'),
                                  file_list: FileList.new([], workdir: Dir.pwd),
                                  ui: UI::Console.new(stdout: StringIO.new))
          .resume_cli_string('abc123')

        expect(cli).to include('-m big')
      end
    end

    it 'adds -d <workdir> only when the workdir differs from the current directory' do
      Dir.mktmpdir do |dir|
        cli = described_class.new(harness: harness_with('abc123', 'x'),
                                  file_list: FileList.new([], workdir: dir),
                                  ui: UI::Console.new(stdout: StringIO.new))
          .resume_cli_string('abc123')

        expect(cli).to include("-d #{dir}")
      end
    end
  end
end
