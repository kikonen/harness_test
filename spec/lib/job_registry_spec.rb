# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'output_buffer'
require 'job'
require 'job_registry'
require 'ui/dialog'
require 'harness_config'

RSpec.describe JobRegistry do
  let(:registry) { JobRegistry.new }

  # The minimum harness Task.run reads (the palette is optional, so a plain
  # object answers only what the drain loop asks).
  def spec_harness
    h = Object.new
    h.define_singleton_method(:output_log) { OutputBuffer.new }
    h
  end

  describe 'the flat list (main turn is job #0)' do
    it 'assigns ids in add order, so a main turn added first is job #0' do
      main = registry.add_job(kind: :main)

      expect(main.id).to eq(0)
      expect(registry.jobs).to eq([main])
      expect(registry.job(0)).to equal(main)
    end

    # Owner decision (2026-11-14): the main turn IS job #0, so the registry has
    # no special case and no privileged slot.
    it 'has no special case for the main job' do
      main = registry.add_job(kind: :main)
      child = registry.add_job(kind: :sub_agent, requested_by: main)

      expect(registry.jobs.map(&:id)).to eq([0, 1])
      expect(registry.job(1)).to equal(child)
      expect(main.buffer).not_to equal(child.buffer)
    end

    it 'refuses a kind outside the list' do
      expect {
        registry.add_job(kind: :ghost)
      }.to raise_error(ArgumentError, /unknown job kind/)
    end
  end

  describe 'the ONE fan-in queue' do
    it 'is the only place cross-job order is defined' do
      first = registry.add_job(kind: :main)
      second = registry.add_job(kind: :sub_agent, requested_by: first)

      second.push_event(type: :text, origin: :task, content: 'B spoke second')
      first.push_event(type: :text, origin: :task, content: 'A spoke first')

      # Queue order is the order events were pushed, whatever the job id.
      expect(registry.poll(0)[:job]).to eq(second.id)
      expect(registry.poll(0)[:job]).to eq(first.id)
    end

    it 'records each event into the buffer of the job the event names' do
      first = registry.add_job(kind: :main)
      second = registry.add_job(kind: :sub_agent, requested_by: first)

      second.push_event(type: :text, origin: :task, content: 'from the sub-agent')
      first.push_event(type: :text, origin: :harness, content: 'from the main turn')

      registry.tick(0)
      registry.tick(0)

      expect(second.buffer.tail.map(&:content)).to eq(['from the sub-agent'])
      expect(first.buffer.tail.map(&:content)).to eq(['from the main turn'])
    end

    it 'never puts two jobs same-key writes into one cell' do
      first = registry.add_job(kind: :main)
      second = registry.add_job(kind: :command, requested_by: first)

      # mode: :append is what makes the write a live head cell (a stream that
      # grows); the key inside each buffer stays (origin, type).
      first.push_event(
        type: :response, origin: :task, content: 'answer from job 0', mode: :append)
      second.push_event(
        type: :response, origin: :task, content: 'answer from job 1', mode: :append)

      registry.tick(0)
      registry.tick(0)

      expect(first.buffer.cell(:task, :response).content).to eq('answer from job 0')
      expect(second.buffer.cell(:task, :response).content).to eq('answer from job 1')
    end

    # A dropped job cannot be answered or read, so an event naming an unknown
    # job is not recorded into anything.
    it 'ignores an event naming a job it does not retain' do
      kept = JobRegistry.new(tasks_kept: 1)
      fg = kept.add_job(kind: :command)
      dropped = kept.add_job(kind: :command, requested_by: fg)
      dropped.finish
      kept.add_job(kind: :command, requested_by: fg).finish

      event = dropped.push_event(type: :text, origin: :task, content: 'orphan')
      expect(kept.record(event)).to be_nil
      expect(dropped.buffer.tail).to be_empty
    end

    it 'poll returns nil on a quiet tick' do
      registry.add_job(kind: :main)

      expect(registry.tick(0)).to be_nil
    end
  end

  describe 'the executor (a turn is awaited, not run in place)' do
    # The drain loop is still the single writer of the job's buffer, so a run
    # through the registry lands the block's value as the awaited result.
    it 'runs a job and reads its result back' do
      job = registry.add_job(kind: :main)
      io = StringIO.new

      error, _task, result = registry.run(job:, harness: spec_harness,
                                          ui: UI::Console.new(stdout: io, stdin: StringIO.new)) do
        :turn_value
      end

      expect(error).to be_nil
      expect(result).to eq(:turn_value)
      expect(job.result).to eq(:turn_value)
    end
  end

  # The spinner check reads the ONE queue, so a job with no waiting event is
  # the quiet case everywhere.
  describe '#queue_empty?' do
    it 'is true on a quiet queue' do
      registry.add_job(kind: :main)
      expect(registry.queue_empty?).to be true
    end

    it 'is false while an event waits' do
      registry.add_job(kind: :main).push_event(type: :text, content: 'line')
      expect(registry.queue_empty?).to be false
    end
  end

  describe 'foreground' do
    it 'the first job added is the active one' do
      main = registry.add_job(kind: :main)

      expect(registry.foreground).to eq(main.id)
      expect(registry.foreground_job).to equal(main)
      expect(registry.foreground_buffer).to equal(main.buffer)
    end

    it 'switching the foreground job is a question of which head is shown' do
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)
      other.buffer.puts(:task, 'background line')
      main.buffer.puts(:task, 'foreground line')

      registry.foreground = other.id

      expect(registry.foreground).to eq(other.id)
      expect(registry.foreground_buffer).to equal(other.buffer)
    end

    # The foreground is remembered as an ID so a resumed run restores it; the
    # buffer itself is not what the session stores.
    it 'stores only the id, so a resumed run can restore which buffer was active' do
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)

      registry.foreground = other.id

      resumed = JobRegistry.new
      resumed.add_job(kind: :main)
      node = resumed.add_job(kind: :command, requested_by: resumed.jobs.first)
      resumed.foreground = node.id

      expect(resumed.foreground).to eq(other.id)
    end

    it 'refuses a foreground switch to a job it does not retain' do
      registry.add_job(kind: :main)

      expect { registry.foreground = 7 }.to raise_error(ArgumentError, /not retained/)
    end
    # The session stores the foreground as an ID, so a resumed run restores it on
    # the registry it built. An id this run does not retain cannot be restored.
    it 'restores a saved id that this run retains' do
      resumed = JobRegistry.new
      resumed.add_job(kind: :main)
      node = resumed.add_job(kind: :command, requested_by: resumed.jobs.first)
      resumed.restore_foreground(node.id)
      expect(resumed.foreground).to eq(node.id)
    end

    it 'leaves the default in place for an id it does not retain' do
      resumed = JobRegistry.new
      resumed.add_job(kind: :main)

      expect(resumed.restore_foreground(9)).to eq(0)
    end
  end

  describe 'main-thread output goes to the FOREGROUND buffer' do
    # The single-writer rule from increment 6, now reading the foreground buffer
    # rather than a run-level one.
    it 'records a main-thread line in the foreground job buffer' do
      main = registry.add_job(kind: :main)
      background = registry.add_job(kind: :command, requested_by: main)
      registry.foreground = background.id

      event = {
        type: :text, origin: :command, content: 'status line', job: background.id }
      registry.record(event)

      expect(background.buffer.tail.map(&:content)).to eq(['status line'])
      expect(main.buffer.tail).to be_empty
    end
  end

  describe 'inbox routing (registry -> job)' do
    it 'routes an answer to the RIGHT job inbox, not a shared one' do
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)

      registry.answer(other.id, '3')
      registry.answer(main.id, 'yes')

      expect(other.inbox.pop(true)).to eq('3')
      expect(main.inbox.pop(true)).to eq('yes')
    end

    # A denied background dialog must come back as a VALUE the tool can return
    # to the model - DialogTool#execute blocks on task.request(:dialog, ...), so
    # a bare refusal is not an answer it can act on.
    it 'a denied background dialog comes back as an answer value, not as silence' do
      main = registry.add_job(kind: :main)
      background = registry.add_job(kind: :command, requested_by: main)

      denied = registry.answer(background.id, 'error: dialog denied (background job)')

      expect(denied).to be_a(String)
      expect(background.poll(0)).to eq(denied)
    end

    # Grant dialogs cannot be denied for a background job because denying them
    # would stop the job from working at all, so the consent path stays live.
    it 'a grant dialog is not denied - the answer reaches the job inbox' do
      main = registry.add_job(kind: :main)
      background = registry.add_job(kind: :command, requested_by: main)

      registry.answer(background.id, 'allow')

      expect(background.poll(0)).to eq('allow')
    end

    # The predicate the drain loop asks when a request lands: only the foreground
    # job can be shown a dialog, and a grant dialog is never denied.
    describe 'denied?' do
      def grant_dialog
        UI::Dialog.new(title: 'grant?',
                       options: [UI::Dialog::Option.new(title: 'Allow', value: :allow)],
                       grant: true)
      end

      def plain_dialog
        UI::Dialog.new(title: 'pick one',
                       options: [UI::Dialog::Option.new(title: 'Yes', value: :yes)])
      end

      it 'denies a dialog for a background job' do
        main = registry.add_job(kind: :main)
        background = registry.add_job(kind: :command, requested_by: main)

        expect(registry.denied?(background, plain_dialog)).to be true
        expect(registry.denied?(main, plain_dialog)).to be false
      end

      it 'never denies a grant dialog, even for a background job' do
        main = registry.add_job(kind: :main)
        background = registry.add_job(kind: :command, requested_by: main)

        expect(registry.denied?(background, grant_dialog)).to be false
      end
    end

    # A steering input overrides a pending note-event ONLY if that pending event
    # is itself a note-event; otherwise it queues behind it (owner rule).
    it 'a note overrides a pending note, and queues behind a non-note event' do
      main = registry.add_job(kind: :main)

      note1 = { type: :note, content: 'first note' }
      note2 = { type: :note, content: 'latest line wins' }
      other = { type: :text, content: 'a non-note event' }

      main.deliver(note1)
      main.deliver(note2)
      expect(main.poll(0)).to eq(note2)

      main.deliver(other)
      main.deliver(note2)
      expect(main.poll(0)).to eq(other)
      expect(main.poll(0)).to eq(note2)
    end

    it 'answers nothing for a job it does not retain' do
      expect(registry.answer(9, 'x')).to be_nil
    end
  end

  describe 'the config value it enforces' do
    # The first consumer wiring: the config value reaches a JobRegistry unchanged,
    # so the config limit IS the retention limit.
    it 'is a config value passed through to a JobRegistry unchanged' do
      config = HarnessConfig.new(output: { tasks_kept: 2 })
      kept = JobRegistry.new(tasks_kept: config.output_tasks_kept)
      fg = kept.add_job(kind: :command)
      3.times { kept.add_job(kind: :command, requested_by: fg).finish }
      fg.finish

      # Measured: the finished foreground job occupies one of the tasks_kept
      # slots, so only the two newest finished jobs survive it (job 1 and job 2
      # were dropped as they became the oldest).
      expect(kept.tasks_kept).to eq(2)
      expect(kept.jobs.map(&:id)).to eq([0, 3])
    end
  end

  describe 'retention (tasks_kept - first consumer of the key)' do
    it 'defaults to nil, so nothing is dropped' do
      expect(JobRegistry.new.tasks_kept).to be_nil

      3.times { registry.add_job(kind: :command, requested_by: registry.jobs.first) }
      registry.jobs.each(&:finish)

      expect(registry.jobs.size).to eq(3)
    end

    it 'keeps at most tasks_kept finished jobs' do
      kept = JobRegistry.new(tasks_kept: 2)
      main = kept.add_job(kind: :main)
      4.times { kept.add_job(kind: :command, requested_by: main) }
      # Snapshot so a drop during #finish cannot skip a job in the iteration.
      kept.jobs.dup.each(&:finish)

      # Measured: a finished foreground job OCCUPIES one of the tasks_kept slots
      # but is never itself dropped, so the main turn stays and the two newest
      # finished jobs fill the rest.
      expect(kept.jobs.map(&:id)).to eq([0, 4])
    end

    it 'never drops a running or pending job' do
      kept = JobRegistry.new(tasks_kept: 1)
      main = kept.add_job(kind: :main)
      running = kept.add_job(kind: :command, requested_by: main)
      running.mark_running
      done = kept.add_job(kind: :command, requested_by: main)
      done.finish

      kept.add_job(kind: :command, requested_by: main).finish
      kept.add_job(kind: :command, requested_by: main).finish

      # The running job was never a drop candidate, so it survives the trim.
      expect(kept.jobs).to eq([main, running, kept.jobs.last])
    end

    it 'drops the OLDEST finished jobs first' do
      kept = JobRegistry.new(tasks_kept: 2)
      main = kept.add_job(kind: :command)
      first = kept.add_job(kind: :command, requested_by: main)
      second = kept.add_job(kind: :command, requested_by: main)

      first.finish
      second.finish
      expect(kept.jobs.size).to eq(3)

      third = kept.add_job(kind: :command, requested_by: main)
      third.finish

      # Foreground is job #0 here, so the two newest finished jobs are kept.
      expect(kept.jobs.map(&:id)).to eq([0, 2, 3])
    end

    # The drop is not a plain "keep last N": a buffer's max_memory never cuts a
    # pending entry, and a dropped job cannot be read, so retention only removes
    # whole finished jobs.
    it 'a dropped job is gone from the list, not just emptied' do
      kept = JobRegistry.new(tasks_kept: 1)
      fg = kept.add_job(kind: :command)
      old = kept.add_job(kind: :command, requested_by: fg)
      old.buffer.puts(:task, 'its record')
      old.finish
      newest = kept.add_job(kind: :command, requested_by: fg)
      newest.finish

      expect(kept.jobs).to eq([fg, newest])
      expect(kept.job(old.id)).to be_nil
    end
  end

  describe '#to_s' do
    it 'lists the jobs and names the foreground one' do
      main = registry.add_job(kind: :main)
      registry.add_job(kind: :command, requested_by: main)

      expect(registry.to_s).to eq(
        'registry: job #0 main pending, job #1 command pending (foreground job #0)')
    end
  end
end
