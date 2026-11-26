# frozen_string_literal: true

require 'event_queue'
require 'queued_event'

# EventQueue: the per-job two-zone queue (issue #286 step 2). These specs pin
# the queue rules; the worker wiring arrives at step 3.
RSpec.describe EventQueue do
  def prompt(text = 'go', job_id: 0)
    QueuedEvent.build(kind: :prompt, job_id:, payload: text)
  end

  def note(text, job_id: 0)
    QueuedEvent.build(kind: :note, job_id:, payload: text)
  end

  def stop(job_id: 0)
    QueuedEvent.build(kind: :stop, job_id:)
  end

  def block_event(kind = :compact, job_id: 0)
    QueuedEvent.build(kind:, job_id:, block: -> {})
  end

  describe 'inbox -> staged' do
    it 'post is non-blocking and admit_next pulls the event in arrival order' do
      queue = described_class.new
      first = queue.post(prompt('one'))
      queue.post(note('two'))

      expect(queue.admit_next).to equal(first)
      expect(queue.pending_kinds).to eq([:prompt])
      expect(queue.admit_next).to have_attributes(kind: :note)
      expect(queue.pending_kinds).to eq(%i[prompt note])
    end

    it 'admit_next returns nil on timeout and admits nothing' do
      queue = described_class.new

      expect(queue.admit_next(timeout: 0.01)).to be_nil
      expect(queue.staged_size).to eq(0)
    end

    it 'admit_arrived drains everything already posted in one step' do
      queue = described_class.new
      queue.post(prompt('a'))
      queue.post(stop)
      queue.post(note('b'))

      expect(queue.admit_arrived).to eq(3)
      expect(queue.pending_kinds).to eq(%i[prompt stop note])
      expect(queue.admit_arrived).to eq(0)
    end

    it 'post is legal from another thread (the cross-thread channel)' do
      queue = described_class.new
      event = nil
      Thread.new { sleep 0.01; event = queue.post(prompt('late')) }

      expect(queue.admit_next(timeout: 2)).to equal(event)
    end
  end

  describe 'peek and dispatch (the processing window)' do
    it 'peek_processable returns the first staged event the window accepts' do
      queue = described_class.new
      queue.post(note('steer'))
      queue.post(prompt('run'))
      queue.admit_arrived

      head = queue.peek_processable(accepted_kinds: [:note])

      expect(head).to have_attributes(kind: :note)
      # peeking does not remove: the note stays until dispatched.
      expect(queue.staged_size).to eq(2)
      expect(queue.dispatch(head)).to equal(head)
      expect(queue.pending_kinds).to eq([:prompt])
    end

    it 'an event outside the window stays staged in arrival order' do
      queue = described_class.new
      queue.post(prompt('run'))
      queue.post(note('steer'))
      queue.admit_arrived

      expect(queue.peek_processable(accepted_kinds: [:note]))
        .to have_attributes(kind: :note)
      expect(queue.peek_processable(accepted_kinds: [])).to be_nil
      expect(queue.pending_kinds).to eq(%i[prompt note])
    end

    it 'control kinds are always processable, whatever the window' do
      queue = described_class.new
      queue.post(stop)
      queue.admit_arrived

      expect(queue.peek_processable(accepted_kinds: []))
        .to have_attributes(kind: :stop)
    end
  end

  describe 'discard_up_to (the :stop rule)' do
    it 'discards staged work up to and including the stop; later events survive' do
      queue = described_class.new
      queue.post(prompt('doomed'))
      queue.post(block_event)
      queue.post(stop)
      queue.post(note('after'))
      queue.admit_arrived

      discarded = queue.discard_up_to(:stop)

      expect(discarded.map(&:kind)).to eq(%i[prompt compact stop])
      expect(queue.pending_kinds).to eq([:note])
    end

    it 'discards nothing when no such kind is staged' do
      queue = described_class.new
      queue.post(prompt('fine'))
      queue.admit_arrived

      expect(queue.discard_up_to(:stop)).to eq([])
      expect(queue.pending_kinds).to eq([:prompt])
    end
  end

  describe 'pending_kinds (the posting snapshot the main thread reads)' do
    it 'is a fresh array in arrival order, duplicates kept, inbox excluded' do
      queue = described_class.new
      queue.post(note('a'))
      queue.admit_arrived
      queue.post(note('b')) # still in the inbox, not staged

      kinds = queue.pending_kinds
      kinds << :prompt

      expect(queue.pending_kinds).to eq([:note])
      expect(queue.inbox_empty?).to be false
    end
  end
end
