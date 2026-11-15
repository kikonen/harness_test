# frozen_string_literal: true

require 'spec_helper'
require 'output_buffer'
require 'job'
require 'job_registry'

RSpec.describe Job do
  # The job's buffer and queue always come from a registry, so a spec that
  # asserts on a job must add it to one - a job the registry does not retain
  # cannot be answered or recorded into.
  let(:registry) { JobRegistry.new }

  def add(node_kind, **kwargs)
    registry.add_job(kind: node_kind, **kwargs)
  end

  describe 'the node shape' do
    it 'has an id, a kind, a status, its own buffer and its own inbox' do
      job = add(:main)

      expect(job.id).to eq(0)
      expect(job.kind).to eq(:main)
      expect(job.status).to eq(:pending)
      expect(job.buffer).to be_a(OutputBuffer)
      expect(job.inbox).to be_a(Thread::Queue)
    end

    # The node has NO outbox: its events go to the registry's ONE queue. This is
    # what keeps cross-job order defined, so a per-job outbox must not come back
    # (issue #286, doc/task_model_design.md).
    it 'has no outbox of its own' do
      expect(add(:main)).not_to respond_to(:outbox)
      expect(add(:main)).not_to respond_to(:outbox_empty?)
    end

    it 'accepts the four kinds on one list' do
      expect(described_class::KINDS).to eq(%i[main sub_agent command timed])

      described_class::KINDS.each do |kind|
        expect(add(kind).kind).to eq(kind)
      end
    end

    it 'refuses a kind outside the list' do
      expect {
        Job.new(id: 1, kind: :ghost, registry:, buffer: OutputBuffer.new)
      }.to raise_error(ArgumentError, /unknown job kind/)
    end

    it 'starts pending and moves to running' do
      job = add(:command)

      expect(job.pending?).to be true
      job.mark_running
      expect(job.running?).to be true
      expect(job.pending?).to be false
    end
  end

  describe 'the awaiting flag (issue #198 FIFO rule)' do
    it 'is not awaiting until the executor posts a request it waits on' do
      expect(add(:command).awaiting?).to be false
    end

    it 'is marked awaiting while a request is unanswered' do
      job = add(:command)
      job.mark_awaiting
      expect(job.awaiting?).to be true
    end

    # The answer IS the delivery, so respond clears the flag with it: this is
    # the one primitive every requester's answer routes through (also what an
    # interrupted turn delivers to a request it still owes).
    it 'clears with the answer a respond delivers' do
      job = add(:command)
      job.mark_awaiting
      job.respond('allow')

      expect(job.awaiting?).to be false
      expect(job.inbox.pop(true)).to eq('allow')
    end
  end

  # The value the caller awaits: the block's value lands as the :done event's
  # result, and the registry's finish is what stores it.
  describe '#result' do
    it 'is nil until the job finishes' do
      expect(add(:main).result).to be_nil
    end

    it 'is the value the finish was given' do
      job = add(:main)
      job.finish('3 findings')
      expect(job.result).to eq('3 findings')
    end
  end

  describe '#push_event (fan-in)' do
    it 'pushes onto the registry queue with the job id on the event' do
      job = add(:main)
      event = job.push_event(type: :text, origin: :task, content: 'from job 0')

      expect(event[:job]).to eq(job.id)
      expect(registry.poll(0)).to eq(event)
    end

    # The job writes nothing itself: the registry is the only writer of the
    # buffer, which is the single-thread I/O rule unchanged.
    it 'never writes its own buffer - the registry is the only writer' do
      job = add(:main)

      job.push_event(type: :text, origin: :task, content: 'hello')
      expect(job.buffer.tail).to be_empty

      registry.tick(0)
      expect(job.buffer.tail.map(&:content)).to eq(['hello'])
    end

    it 'carries extra keys through to the queue' do
      event = add(:main).push_event(
        type: :spinner_detail, origin: :harness, content: { message: 'working' })

      expect(event[:content][:message]).to eq('working')
    end

    it 'normalizes the type to a symbol' do
      event = add(:main).push_event(type: 'text', origin: 'task', content: 'line')

      expect(event[:type]).to eq(:text)
    end
  end

  describe 'the buffer key stays (origin, type)' do
    # Measured in analysis/286/repro.rb: over ONE shared buffer two jobs writing
    # the same (origin, type) stream collapse into one cell and their text is
    # joined; per-job buffers keep them two cells. The job is supplied by WHICH
    # buffer the cell lives in, so the key never gains a third field.
    it 'cannot name itself twice, so the job is not a key field' do
      shared = OutputBuffer.new
      shared.put(
        type: :response, origin: :task, content: 'answer from job 1', mode: :append)
      shared.put(
        type: :response, origin: :task, content: 'answer from job 2', mode: :append)

      expect(shared.head.size).to eq(1)
      expect(shared.cell(:task, :response).content).to eq(
        'answer from job 1answer from job 2')
    end

    it 'per-job buffers keep two same-key writes as two cells' do
      first = add(:sub_agent)
      second = add(:sub_agent, requested_by: first)

      first.buffer.put(
        type: :response, origin: :task, content: 'answer from job 1', mode: :append)
      second.buffer.put(
        type: :response, origin: :task, content: 'answer from job 2', mode: :append)

      expect(first.buffer.head.size).to eq(1)
      expect(second.buffer.head.size).to eq(1)
      expect(first.buffer.cell(:task, :response).content).to eq('answer from job 1')
      expect(second.buffer.cell(:task, :response).content).to eq('answer from job 2')
    end
  end

  describe 'dependencies are preconditions' do
    it 'is ready with no dependencies' do
      expect(add(:main).ready?).to be true
    end

    it 'waits for a job that has not finished' do
      dep = add(:command)
      node = add(:sub_agent, dependencies: [dep])

      expect(node.ready?).to be false
      dep.finish('found 3 callers')
      expect(node.ready?).to be true
    end

    # A timed job's precondition is a clock predicate, not another job, so a
    # plain job-to-job DAG is not enough (issue #181).
    it 'accepts a callable predicate for a non-job precondition' do
      opened = false
      node = add(:timed, dependencies: [-> { opened }])

      expect(node.ready?).to be false
      opened = true
      expect(node.ready?).to be true
    end
  end

  describe '#finish delivers to the requester' do
    it 'delivers the result to the requester inbox, not to a shared one' do
      requester = add(:main)
      child = add(:command, requested_by: requester)

      child.finish('handle pid 4321')

      expect(child.finished?).to be true
      expect(requester.inbox.pop(true)).to eq('handle pid 4321')
    end

    it 'cannot deliver twice (a second finish answers the requester again)' do
      requester = add(:main)
      child = add(:sub_agent, requested_by: requester)

      child.finish('findings')
      child.finish('findings again')

      expect(requester.inbox.size).to eq(1)
    end

    it 'a job with no requester finishes without error' do
      expect(add(:main).finish('done')).to eq('done')
    end
  end

  describe 'the inbox' do
    it 'receives a value from the registry side' do
      job = add(:main)
      expect(job.deliver(:cancel)).to eq(:cancel)

      expect(job.inbox_empty?).to be false
      expect(job.poll(0)).to eq(:cancel)
    end

    # A reply equal to STOP is not an answer: a job must stop rather than treat
    # it as a dialog result.
    it 'the stop sentinel is distinct from an answer value' do
      job = add(:main)
      job.deliver(described_class::STOP)

      answer = job.poll(0)
      expect(answer).to equal(described_class::STOP)
      expect(answer).not_to eq(:cancel)
    end

    it 'poll returns nil when nothing is waiting' do
      expect(add(:main).poll(0)).to be_nil
    end
  end

  describe '#to_s' do
    it 'names the job, its kind and its status' do
      expect(add(:main).to_s).to eq('job #0 main pending')
    end
  end
end
