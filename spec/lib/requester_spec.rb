# frozen_string_literal: true

require 'spec_helper'
require 'registry'
require 'job'
require 'requester'
require 'task'

# A concrete requester stands in for the abstract module: #job and #push_event
# raise on the module itself, so the shared request/respond behaviour is
# exercised through an instance the way a Task or a SubAgent uses it.
class SpecRequester
  include Requester

  attr_reader :job

  def initialize(job)
    @job = job
  end

  def push_event(**event)
    # SubAgent#push_event is exactly this delegation, so the job-id tag the
    # pin asserts on comes from Job#push_event, not from the spec.
    job.push_event(**event)
  end
end

RSpec.describe Requester do
  let(:registry) { Registry.new }

  describe '#current' do
    after do
      Thread.current[:harness_task] = nil
      Thread.current[:harness_sub_agent] = nil
    end

    it 'resolves the requester running on the current thread' do
      Thread.current[:harness_sub_agent] = :round
      expect(described_class.current).to eq(:round)
    end

    # Task is checked FIRST so every existing pin that stubs Task.current holds.
    it 'checks Task first' do
      Thread.current[:harness_task] = :turn
      Thread.current[:harness_sub_agent] = :round
      expect(described_class.current).to eq(:turn)
    end
  end

  describe 'request / respond' do
    it 'posts a request event naming its job and blocks for the answer' do
      job = registry.add_job(kind: :main)
      requester = SpecRequester.new(job)
      reply = nil
      thread = Thread.new { reply = requester.request(:test, key: 'value') }

      event = nil
      20.times do
        event = registry.poll(0.5)
        break if event
      end
      expect(event[:type]).to eq(:__request__)
      expect(event[:kind]).to eq(:test)
      expect(event[:key]).to eq('value')
      expect(event[:job]).to eq(job.id)

      requester.respond('the_answer')
      thread.join(2)
      expect(reply).to eq('the_answer')
    end

    # An input event that arrives while a request is unanswered must queue
    # BEHIND the answer, which is what the awaiting flag gates in route_input.
    it 'marks the job awaiting while a request is unanswered' do
      job = registry.add_job(kind: :main)
      requester = SpecRequester.new(job)
      thread = Thread.new { requester.request(:test) }

      20.times do
        break if registry.poll(0.5)
      end
      expect(job.awaiting?).to be true

      # The answer clears the flag with the delivery.
      requester.respond('yes')
      thread.join(2)
      expect(job.awaiting?).to be false
    end

    it 'raises when the requester is stopped while waiting' do
      job = registry.add_job(kind: :main)
      requester = SpecRequester.new(job)
      error = nil
      thread = Thread.new do
        begin
          requester.request(:forever)
        rescue RuntimeError => e
          error = e
        end
      end
      20.times do
        break if registry.poll(0.5)
      end
      job.inbox << Job::STOP
      thread.join(2)

      expect(error.message).to include('stopped while waiting for response to')
    end

    # A task and a round can block on the SAME job inbox, so two distinct
    # sentinels could not both recognize the stop.
    it 'shares the STOP sentinel with Task' do
      expect(Task::STOP).to equal(Job::STOP)
    end
  end
end
