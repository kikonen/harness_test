# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'input_path'
require 'job_registry'

# The ONE input path (issue #286): the idle prompt and a mid-turn note are the
# same read, so the edit state is a state of the single poll loop. A submitted
# block is ONE input event routed to the target job's inbox.
RSpec.describe InputPath do
  let(:registry) { JobRegistry.new }
  let(:stdin_io) { StringIO.new }
  let(:ui) { instance_double(UI::Console) }
  let(:editor) { instance_double(UI::Editor) }

  def build(**kwargs)
    described_class.new(ui:, editor:, **kwargs)
  end

  def result(text, status)
    UI::Editor::EDITOR_RESULT.new(text, status)
  end

  before do
    allow(ui).to receive(:stdin).and_return(stdin_io)
    allow(UI::Editor).to receive(:new).with(stdin_io).and_return(editor)
  end

  describe 'the edit state (a state of the poll loop)' do
    it 'is off until a keypress is seen' do
      expect(build.edit_state?).to be false
    end

    it 'is entered when the peek sees a keypress' do
      allow(stdin_io).to receive(:input_pending?).and_return(true)
      path = build

      expect(path.pending?).to be true
      expect(path.edit_state?).to be true
    end

    # issue #473: a stream that cannot answer the peek never enters the state.
    it 'never enters the state for a stream that cannot answer the peek' do
      allow(stdin_io).to receive(:input_pending?).and_return(false)
      path = build

      expect(path.pending?).to be false
      expect(path.edit_state?).to be false
    end

    it 'leaves the state when the read returns' do
      allow(stdin_io).to receive(:input_pending?).and_return(true)
      allow(editor).to receive(:read_multiline).and_return(result('a note', :submitted))
      path = build

      path.pending?
      path.read

      expect(path.edit_state?).to be false
    end
  end

  describe 'the read' do
    it 'reads one multiline block through the editor' do
      allow(editor).to receive(:read_multiline).and_return(result('the block', :submitted))

      expect(build.read.text).to eq('the block')
    end

    # The caller keeps its own draft (the prompt keeps it, a running turn keeps
    # the task's note draft), so the path takes only the prefill.
    it 'a round trip is never a submission' do
      expect(described_class::ROUND_TRIP).to eq(%i[edited cancelled empty])
    end

    it 'the prompt label belongs to the reader, not the path' do
      allow(editor).to receive(:read_multiline)
      build(prompt: '  ').read

      expect(editor).to have_received(:read_multiline).with(prompt: '  ', prefill: nil)
    end
  end

  describe 'routing one submitted block as ONE input event' do
    it 'routes to the target job inbox through the registry' do
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)
      path = build(registry:, target: -> { other })

      path.route('steering note')

      expect(other.poll(0)).to eq({ type: :note, content: 'steering note' })
      expect(main.inbox.empty?).to be true
    end

    # The target is read live, so a foreground switch changes where the next
    # event goes without rebuilding the reader.
    it 'reads the target live, so a foreground switch re-routes the next event' do
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)
      path = build(registry:, target: -> { registry.foreground_job })

      path.route('to job 0')
      registry.foreground = other.id
      path.route('to job 1')

      expect(main.poll(0)).to eq({ type: :note, content: 'to job 0' })
      expect(other.poll(0)).to eq({ type: :note, content: 'to job 1' })
    end

    # Without a registry there is no inbox to write - the FIFO rule lives in the
    # registry, so a bare path only names the event.
    it 'still names the event without a registry (unit-test path)' do
      expect(build.route('a note')).to eq({ type: :note, content: 'a note' })
    end
  end
end
