# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'cli'

# issue #189: the startup banner shows the session id and where its log is
# written, so the user can find harness.log without guessing.

RSpec.describe CLI do
  let(:workdir) { Dir.mktmpdir }
  let(:ui) { instance_double(UI::Console) }
  let(:options) do
    {
      workdir:   workdir,
      base_url:  'http://localhost:11434/v1',
      model:     'test-model',
      system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE
    }
  end

  def build_cli
    described_class.new(options, ui)
  end

  describe '#session_log_path_display' do
    it 'is the per-session log path relative to the workdir' do
      cli = build_cli
      id  = cli.harness.session.session_id

      expect(cli.send(:session_log_path_display))
        .to eq(File.join('.harness', 'sessions', id, 'harness.log'))
    end
  end

  # issue #221 review (bug 2): the shell consent posture is stated in the
  # startup banner so the run's approval behavior is visible from the first
  # line (YOLO ON must never look like "nothing ever asks").
  describe 'startup banner - command consent posture' do
    it 'names the MANUAL posture and how to change it' do
      cli = build_cli
      allow(cli).to receive(:get_command).and_return(nil)

      expect(ui).to receive(:puts)
        .with(/^Command consent: MANUAL - unapproved commands ask/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    it 'names YOLO with the disaster floor still asking' do
      cli = build_cli
      allow(cli).to receive(:get_command).and_return(nil)
      cli.harness.yolo = true

      expected = 'Command consent: YOLO - unapproved commands run ' \
                 'without asking; disaster commands still ask'
      expect(ui).to receive(:puts)
        .with(expected)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end
  end

  describe '#run' do
    it 'prints the session id and its log path in the banner' do
      cli = build_cli
      id  = cli.harness.session.session_id
      allow(cli).to receive(:get_command).and_return(nil)

      expect(ui).to receive(:puts)
        .with(/Session: #{Regexp.escape(id)} \(log: .*harness\.log\)/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end
  end

  # issue #198 phase 3: the idle prompt keeps an Esc'd buffer as a draft
  # (prefilled at the next prompt), re-prompts on bare Enter, and only
  # returns a submitted command or nil (Ctrl-D eof => quit).
  describe '#get_command' do
    let(:cli) { build_cli }
    let(:editor) { instance_double(UI::Editor) }
    let(:stdin_io) { StringIO.new }

    before do
      allow(ui).to receive(:puts)
      allow(ui).to receive(:stdin).and_return(stdin_io)
      allow(ui).to receive(:flush)
      allow(cli.harness.session_manager).to receive(:active_model_name)
                                        .and_return('test-model')
      allow(cli.harness).to receive(:context_indicator).and_return(nil)
      @result_class = UI::Editor::EDITOR_RESULT
      allow(UI::Editor).to receive(:new).with(stdin_io).and_return(editor)
    end

    def editor_result(text, status)
      @result_class.new(text, status)
    end

    it 'returns the submitted text and clears the draft' do
      allow(editor).to receive(:read_multiline).and_return(
        editor_result('hello world', :submitted))

      expect(cli.send(:get_command)).to eq('hello world')
    end

    # issue #221 review (bug 2): the prompt modeline carries the consent
    # posture bracket next to the model bracket, so it is visible on every
    # turn (the spinner only exists while the model works).
    it 'shows the consent posture in the prompt modeline' do
      allow(editor).to receive(:read_multiline).and_return(
        editor_result('x', :submitted))

      expect(ui).to receive(:puts).with(/test-model .* \[cmd: MANUAL\] > /)

      cli.send(:get_command)
    end

    it 'shows [cmd: YOLO] in the prompt modeline when YOLO is on' do
      allow(editor).to receive(:read_multiline).and_return(
        editor_result('x', :submitted))
      cli.harness.yolo = true

      expect(ui).to receive(:puts).with(/\[cmd: YOLO\] > /)

      cli.send(:get_command)
    end

    it 'keeps a cancelled buffer as the draft and re-prompts' do
      allow(editor).to receive(:read_multiline).and_return(
        editor_result('partial', :cancelled),
        editor_result('partial done', :submitted))

      expect(cli.send(:get_command)).to eq('partial done')
      expect(editor).to have_received(:read_multiline)
                     .with(prompt: '  ', prefill: nil)
      expect(editor).to have_received(:read_multiline)
                     .with(prompt: '  ', prefill: 'partial')
    end

    it 're-prompts on a bare Enter without touching the draft' do
      allow(editor).to receive(:read_multiline).and_return(
        editor_result('', :empty),
        editor_result('cmd', :submitted))

      expect(cli.send(:get_command)).to eq('cmd')
    end
  end
end
