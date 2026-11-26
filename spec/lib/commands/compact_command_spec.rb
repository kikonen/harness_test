# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'logger'
require 'job_registry'
require 'commands/compact_command'

# issue #70: /compact must report the resulting context size so the user can
# verify that compaction freed space without burning tokens on a follow-up.
#
# issue #253: the summary is an LLM round, so it must run on a Task thread
# (the single-thread I/O rule, issue #40). Output lines are emitted through
# the task event queue (Reporting#emit_line), not written to a stream from
# the task thread. The command reaches the Harness through the foreground
# job's harness (#286), so the spec carries the harness on a real registry's
# main job; increment 4c runs the round for real: a parked worker on the
# registry and a MainLoop double whose begin_turn/await_turn drain the queue
# the way the loop's drain state does (record + render to :done).
RSpec.xdescribe Commands::CompactCommand do
  let(:session) { Session.new('system prompt', file_cache: SessionFileCache.new) }
  let(:result) do
    {
      summary: 'summary text',
      before: 10,
      after: 4,
      retained: 2,
      context_before: '🧠 ctx ~62100/65536 (95%)',
      context_line: '🧠 ctx ~523/65536 (1%)'
    }
  end
  let(:manager) { double('session_manager', compact_session: result) }

  # A minimal stand-in for Harness providing only what the command uses.
  def build_harness
    Class.new do
      attr_accessor :session, :session_manager

      # Task#record_task_error logs a raising turn through the harness logger.
      def logger = @logger ||= Logger.new(File::NULL)

      # Task#prepare reads the renderer settings off the harness.
      def settings
        @settings ||= Class.new do
          def output_palette = nil
          def markdown?      = false
          def markdown_max_width = nil
        end.new
      end

      def initialize(session, manager)
        @session         = session
        @session_manager = manager
      end
    end.new(session, manager)
  end

  let(:harness) { build_harness }
  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  # A real registry whose main job carries the harness (#286): the command reads
  # the harness through registry.foreground_job.harness.
  def registry_with_harness
    JobRegistry.new.tap { |r| r.add_job(kind: :main, harness:) }
  end

  # A MainLoop stand-in for the drain state (#286 step 3): begin_turn posts
  # the QueuedEvent on the parked worker's EventQueue, drains the queue the
  # way the loop ticks it (record + render until that job's :done), and
  # returns the JOB. The command spec drives no run loop, so the double
  # drains inline.
  def loop_double(registry, worker, console: ui)
    loop_ = Object.new
    loop_.define_singleton_method(:begin_turn) do |event|
      worker.job.mark_running
      worker.event_queue.post(event)
      job = worker.job
      # The worker pushes :done in its ensure, so the drain ends there - the
      # worker thread may still be inside its ensure when :done is polled.
      finished = false
      until finished
        event = registry.poll(0.1)
        next if event.nil?

        registry.record(event)
        finished = event[:type] == :done && event[:job] == job.id

        line = worker.renderer.line(type: event[:type],
                                    content: event[:content], origin: event[:origin])
        console.puts(line)
      end
      job
    end
    # Command#turn_live? reads live-ness off the loop's shown job.
    loop_.define_singleton_method(:shown_job) { worker.job }
    loop_
  end

  def command
    registry = registry_with_harness
    worker   = registry.worker_for(registry.foreground_job, ui:)
    described_class.new(file_list: nil, registry:, ui:,
                        main_loop: loop_double(registry, worker))
  end

  it 'runs the compaction inside a Task (I/O routed through the drain loop)' do
    command.handle('')

    expect(manager).to have_received(:compact_session)
  end

  it 'prints the resulting context size after compaction' do
    command.handle('')

    expect(io.string).to include(
      "Session compacted: 10 messages -> 4 messages (2 recent retained)."
    )
    expect(io.string).to include(
      "🧠 ctx ~62100/65536 (95%) -> 🧠 ctx ~523/65536 (1%)"
    )
    expect(io.string).to include("Summary:\nsummary text")
  end

  it 'omits the context line when before or after is missing' do
    result[:context_before] = nil

    command.handle('')
    expect(io.string).not_to match(/🧠 ctx/)

    result[:context_before] = '🧠 ctx ~62100/65536 (95%)'
    result[:context_line]   = nil

    command.handle('')
    expect(io.string).not_to match(/🧠 ctx/)

    result[:context_before] = '🧠 ctx ~62100/65536 (95%)'
    result[:context_line]   = '🧠 ctx ~523/65536 (1%)'
  end

  # The [task error] line is the LOOP's report (its drain state hands the error
  # to CommandHandler#report_turn_error), so a command spec no longer asserts
  # it - it asserts the worker SURVIVES a raising round.
  it 'keeps the worker parked after a raising round' do
    registry = registry_with_harness
    worker   = registry.worker_for(registry.foreground_job, ui:)
    allow(manager).to receive(:compact_session).and_raise(RuntimeError, 'boom')
    cmd = described_class.new(file_list: nil, registry:, ui:,
                              main_loop: loop_double(registry, worker))

    cmd.handle('')

    expect(worker.alive?).to be true
  end

  it 'emits lines as task events instead of writing to the stream' do
    registry = registry_with_harness
    worker   = registry.worker_for(registry.foreground_job, ui:)
    cmd = described_class.new(file_list: nil, registry:, ui:,
                              main_loop: loop_double(registry, worker))

    cmd.handle('')

    # The command thread wrote nothing to the stream: the console holds only
    # what the drain rendered from the job's event record.
    expect(registry.foreground_job.buffer.tail.map(&:content)).to include(
      'Session compacted: 10 messages -> 4 messages (2 recent retained).'
    )
    expect(registry.foreground_job.buffer.tail.map(&:origin).uniq).to eq([:command])
  end
end
