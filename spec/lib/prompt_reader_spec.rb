# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'prompt_reader'

# PromptReader owns the idle-prompt read: modeline + UI::Editor read + draft.
# A stub harness is enough (Task.mode_badge is covered in task_spec); the
# harness is passed as a callable because a mid-run /resume swaps it.
RSpec.describe PromptReader do
  let(:ui) { instance_double(UI::Console) }
  let(:editor) { instance_double(UI::Editor) }
  let(:stdin_io) { StringIO.new }

  # A harness stub carrying only what the modeline reads.
  def harness_stub(model: 'test-model', effort: 'medium',
                   command_label: 'MANUAL', stream_label: nil,
                   plan_label: nil, ctx: nil)
    sm = Object.new
    sm.define_singleton_method(:active_model_name) { model }
    po = Object.new
    po.define_singleton_method(:reasoning_effort_display) { effort }
    sm.define_singleton_method(:param_overrides) { po }
    h = Object.new
    h.define_singleton_method(:session_manager) { sm }
    h.define_singleton_method(:command_mode_label) { command_label }
    h.define_singleton_method(:stream_mode_label) { stream_label }
    h.define_singleton_method(:plan_mode_label) { plan_label }
    h.define_singleton_method(:context_indicator) { ctx }
    h
  end

  def build_reader(harness = harness_stub)
    described_class.new(ui: ui, harness: -> { harness })
  end

  def editor_result(text, status, note = nil)
    UI::Editor::EDITOR_RESULT.new(text, status, note)
  end

  before do
    allow(ui).to receive(:puts)
    allow(ui).to receive(:stdin).and_return(stdin_io)
    allow(ui).to receive(:flush)
    allow(UI::Editor).to receive(:new).with(stdin_io).and_return(editor)
  end

  it 'returns the submitted text' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('hello world', :submitted))

    expect(build_reader.read).to eq('hello world')
  end

  it 'returns nil on eof (Ctrl-D on an empty buffer => quit)' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('', :eof))

    expect(build_reader.read).to be_nil
  end

  # issue #221 review (bug 2): the prompt modeline carries the consent posture
  # bracket next to the model bracket, so it is visible on every turn.
  it 'shows the consent posture in the prompt modeline' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('x', :submitted))

    expect(ui).to receive(:puts).with(/test-model .* \[MANUAL\] > /)

    build_reader.read
  end

  it 'shows [YOLO] in the prompt modeline when the consent label is YOLO' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('x', :submitted))

    expect(ui).to receive(:puts).with(/\[YOLO\] > /)

    build_reader(harness_stub(command_label: 'YOLO')).read
  end

  # issue #387: the prompt and the spinner share ONE builder (Task.mode_badge),
  # so a stream-on prompt shows [STREAM] exactly as the spinner does.
  it 'shows [STREAM] in the prompt modeline when streaming is on' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('x', :submitted))

    expect(ui).to receive(:puts).with(/\[MANUAL\] \[STREAM\] > /)

    build_reader(harness_stub(stream_label: 'STREAM')).read
  end

  # Buffered is the default posture, so the tag stays absent (a tag names a
  # non-default). The consent tag is still there.
  it 'shows no [STREAM] tag when streaming is off (the default)' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('x', :submitted))

    expect(ui).to receive(:puts).with(/\[MANUAL\] > /)

    build_reader.read
  end

  it 'renders the context indicator on the modeline line when present' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('x', :submitted))

    expect(ui).to receive(:puts).with(/ctx: 1k\/8k .* \[MANUAL\] > /)

    build_reader(harness_stub(ctx: 'ctx: 1k/8k')).read
  end

  it 'keeps a cancelled buffer as the draft and re-prompts' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('partial', :cancelled),
      editor_result('partial done', :submitted))

    expect(build_reader.read).to eq('partial done')
    expect(editor).to have_received(:read_multiline)
                   .with(prompt: '  ', prefill: nil)
    expect(editor).to have_received(:read_multiline)
                   .with(prompt: '  ', prefill: 'partial')
  end

  it 're-prompts on a bare Enter without touching the draft' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('', :empty),
      editor_result('cmd', :submitted))

    expect(build_reader.read).to eq('cmd')
  end

  # issue #298: Ctrl+G hands the buffer to an external editor. The text the
  # editor produced (carried as :edited) becomes the DRAFT - the submit key is
  # still what sends it, exactly like an Esc'd buffer.
  it 'keeps an edited buffer as the draft and re-prompts' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('from editor', :edited, 'edited with notepad'),
      editor_result('from editor sent', :submitted))

    expect(build_reader.read).to eq('from editor sent')
    expect(editor).to have_received(:read_multiline)
                   .with(prompt: '  ', prefill: 'from editor')
  end

  it 'names the editor on the :edited draft line' do
    allow(editor).to receive(:read_multiline).and_return(
      editor_result('kept', :edited, 'edited with vim'),
      editor_result('go', :submitted))

    printed = []
    allow(ui).to receive(:puts) { |*args| printed << args.join(' ') }

    build_reader.read

    expect(printed).to include(
      '  (edited with vim - draft kept; press the submit key to send)'
    )
  end
end
