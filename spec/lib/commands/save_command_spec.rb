# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'commands/save_command'

RSpec.describe Commands::SaveCommand do
  def harness_with(id, path)
    sm = Object.new
    sm.define_singleton_method(:save_session) { id }
    sm.define_singleton_method(:session_file_path) { |session_id| path % session_id }
    h = Object.new
    h.define_singleton_method(:session_manager) { sm }
    h
  end

  def run_command(file_list, options: { model: 'qwen3:8b' }, id: 'abc123', path: '.harness/sessions/%s/session.json')
    stdout = StringIO.new
    described_class.new(harness: harness_with(id, path), file_list: file_list,
                        options: options, ui: UI::Console.new(stdout: stdout)).handle('')
    stdout.string
  end

  it 'reports the saved id with the file path the session lives at' do
    Dir.mktmpdir do |dir|
      out = run_command(FileList.new([], workdir: dir))

      expect(out).to include('Session saved as abc123')
      expect(out).to include('.harness/sessions/abc123/session.json')
    end
  end

  it 'prints the in-harness resume line (/resume <id>)' do
    Dir.mktmpdir do |dir|
      expect(run_command(FileList.new([], workdir: dir))).to include('Resume it later with: /resume abc123')
    end
  end

  describe 'resume_cli_string' do
    it 'builds the command line with the model and --resume <id>' do
      Dir.mktmpdir do |_dir|
        cli = described_class.new(harness: harness_with('abc123', 'x'),
                                  file_list: FileList.new([], workdir: Dir.pwd),
                                  options: { model: 'qwen3:8b' },
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

    it 'adds -d <workdir> only when the workdir differs from the current directory' do
      Dir.mktmpdir do |dir|
        cli = described_class.new(harness: harness_with('abc123', 'x'),
                                  file_list: FileList.new([], workdir: dir),
                                  options: { model: 'qwen3:8b' },
                                  ui: UI::Console.new(stdout: StringIO.new))
          .resume_cli_string('abc123')

        expect(cli).to include("-d #{dir}")
      end
    end
  end
end
