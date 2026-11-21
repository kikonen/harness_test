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

  # The minimum harness Task.run reads: a non-nil harness answers the whole
  # interface it reads off one (#286: full-or-nil), so plain defaults apply.
  def spec_harness
    h = Object.new
    h.define_singleton_method(:output_log) { OutputBuffer.new }
    h.define_singleton_method(:settings) do
      SystemSettings.from_options({ output_palette: 'none' })
    end
    h.define_singleton_method(:logger) { nil }
    h.define_singleton_method(:plan_mode_label) { nil }
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

    # #548 A: a resumed registry seeds next_id from the saved system's next_id
    # so its next job never reuses an id already on disk.
    it 'starts numbering at a seeded next_id (#548 A)' do
      resumed = JobRegistry.new(next_id: 3)
      job = resumed.add_job(kind: :main)

      expect(job.id).to eq(3)
      expect(resumed.next_id).to eq(4)
    end

    # #548: a resumed run rebuilds a saved job at its SAVED id so the job's live
    # id matches the jobs/<id>/ dir its files live under; next_id stays ahead.
    it 'rebuilds a saved job at its explicit id and keeps next_id ahead (#548)' do
      resumed = JobRegistry.new(next_id: 0)
      job = resumed.add_job(kind: :main, id: 2)

      expect(job.id).to eq(2)
      expect(resumed.next_id).to eq(3)
      expect(resumed.add_job(kind: :sub_agent).id).to eq(3)
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
      job = registry.add_job(kind: :main, harness: spec_harness)
      io = StringIO.new

      error, _task, result = registry.run(job:,
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
    # #548: a resumed run rebuilds its saved jobs at their saved ids and then
    # sets the foreground explicitly with foreground= (no restore_foreground).
    it 'sets a foreground to a job the run rebuilt at its saved id' do
      resumed = JobRegistry.new(next_id: 3)
      resumed.add_job(kind: :main, id: 2)

      resumed.foreground = 2

      expect(resumed.foreground).to eq(2)
      expect(resumed.foreground_job.id).to eq(2)
    end
  end

  # issue #548: a saved system.json names the ids the system had; a resumed
  # registry has only the ids it added itself. Re-resolution reports which saved
  # ids name a live Job - the rest are dropped jobs whose edges stay dangling.
  describe '#resumable_job_ids (issue #548 edge re-resolution)' do
    let(:resumed) { JobRegistry.new.tap { |r| r.add_job(kind: :main) } }

    it 'keeps a saved id this registry has and drops one it has not' do
      resumed.add_job(kind: :command)

      saved = [{ id: 0, kind: 'main' }, { id: 1, kind: 'sub_agent' }, { id: 2, kind: 'timed' }]

      expect(resumed.resumable_job_ids(saved)).to eq([0, 1])
    end

    it 'accepts the raw string ids JSON reads back, and bare ids' do
      expect(resumed.resumable_job_ids([{ 'id' => 0 }, { 'id' => 4 }])).to eq([0])
      expect(resumed.resumable_job_ids([0, 4])).to eq([0])
    end

    it 'is empty for a nil or empty saved list' do
      expect(resumed.resumable_job_ids(nil)).to eq([])
      expect(resumed.resumable_job_ids([])).to eq([])
    end

    it 'reports an id a resumed registry lost to retention as not resumable' do
      expect(resumed.resumable_job_ids([{ id: 0 }, { id: 1 }])).to eq([0])
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

  # issue #458 / #286: the run record lives on the registry (the FOREGROUND job's
  # buffer), not on the single-turn engine. The user's own line is one side of it
  # (role :user), the model/command side the other, and both land through the
  # single main-thread writer. max_saved 0 disables the whole path.
  describe 'run record / resume replay (issue #458)' do
    def recorded(reg) = reg.foreground_buffer.replay_tail

    it 'records a user prompt as a :user/:user entry (the renderer labels it)' do
      reg = JobRegistry.new
      reg.add_job(kind: :main)
      reg.record_user_prompt('fix the parser')

      expect(recorded(reg).map { |e| [e.type, e.origin, e.content] }).to eq(
        [[:user, :user, 'fix the parser']]
      )
    end

    it 'caps the window at max_saved (oldest prompts drop)' do
      reg = JobRegistry.new(max_saved: 2)
      reg.add_job(kind: :main)
      reg.record_user_prompt('one')
      reg.record_user_prompt('two')
      reg.record_user_prompt('three')

      expect(recorded(reg).map(&:content)).to eq(['two', 'three'])
    end

    it 'records the model/tool side through the single writer, spinner stays in the head' do
      reg = JobRegistry.new
      reg.add_job(kind: :main)
      reg.record_report_output(type: :response, origin: 'session_manager', content: 'the answer')
      reg.record_report_output(type: :spinner_detail, origin: :harness,
                               content: { message: 'Working' })
      reg.record_report_output(type: :status_ok, origin: 'file.read', content: 'ok')

      expect(recorded(reg).map(&:type)).to eq(%i[response status_ok])
      expect(reg.foreground_buffer.head.map(&:type)).to eq([:spinner_detail])
    end

    it 'replay_tail_for_save is the Entry#to_h form of the window' do
      reg = JobRegistry.new
      reg.add_job(kind: :main)
      reg.record_user_prompt('do the thing')

      expect(reg.replay_tail_for_save).to eq(
        [{ type: :user, origin: :user, content: 'do the thing' }]
      )
    end

    it 'records nothing when max_saved is 0 (the disable)' do
      reg = JobRegistry.new(max_saved: 0)
      reg.add_job(kind: :main)
      reg.record_user_prompt('ignored')
      reg.record_report_output(type: :response, origin: 'session_manager', content: 'ignored too')

      expect(recorded(reg)).to be_empty
      expect(reg.replay_tail_for_save).to eq([])
    end

    # A resumed run seeds its record from the saved tail so the startup banner can
    # redraw the last topic; restore() re-symbols the JSON's string type/origin.
    it 'seeds the run record from a saved replay_tail' do
      reg = JobRegistry.new
      reg.add_job(kind: :main)
      reg.restore_replay_tail([
        { type: 'user', origin: 'user', content: 'do the thing' },
        { type: 'response', origin: 'session_manager', content: 'done' }
      ])

      expect(recorded(reg).map { |e| [e.type, e.origin, e.content] }).to eq(
        [[:user, :user, 'do the thing'], [:response, :session_manager, 'done']]
      )
    end

    it 'does not seed the run record when max_saved is 0' do
      reg = JobRegistry.new(max_saved: 0)
      reg.add_job(kind: :main)
      reg.restore_replay_tail([{ type: 'user', origin: 'user', content: 'should not appear' }])

      expect(recorded(reg)).to be_empty
    end

    # issue #474: a slash-command report is a structured :list entry (title/
    # columns/items), NOT a fused row string. The payload survives the save ->
    # resume round trip symbol-keyed so a resumed run redraws the structure.
    it 'records a command report as a :list entry holding the structure' do
      reg = JobRegistry.new
      reg.add_job(kind: :main)
      payload = {
        title: 'Hosts:', kind: :bullet, columns: [:value],
        items: [{ value: 'a.example' }, { value: 'b.example' }]
      }
      reg.record_report_output(type: :list, origin: 'grant', content: payload)

      entry = recorded(reg).first
      expect(entry.type).to eq(:list)
      expect(entry.origin).to eq(:grant)
      expect(entry.content).to be_a(Hash)
      expect(entry.content[:items]).to eq([{ value: 'a.example' }, { value: 'b.example' }])
    end
  end

  # issue #548 increment 5: the exit decision asks "does ANY retained job own
  # session state?" across the whole job list, not just the foreground one.
  # issue #548 increment 4b: the saved tail of ANY retained job's own buffer,
  # not only the foreground one (the registry owns every job.buffer).
  describe '#replay_tail_for_job (issue #548)' do
    it 'reads a NON-foreground job buffer tail' do
      reg = JobRegistry.new
      main = reg.add_job(kind: :main)
      child = reg.add_job(kind: :sub_agent, requested_by: main)
      child.buffer.put(type: :response, origin: :session_manager, content: 'child answer')
      child.buffer.keep_window
      reg.foreground = main.id # foreground stays job 0

      expect(reg.replay_tail_for_job(child.id).map { |e| e[:content] }).to eq(['child answer'])
    end

    it 'returns empty for a job the registry does not retain' do
      reg = JobRegistry.new
      reg.add_job(kind: :main)

      expect(reg.replay_tail_for_job(99)).to eq([])
    end

    it 'returns empty when the saved window is disabled' do
      reg = JobRegistry.new(max_saved: 0)
      child = reg.add_job(kind: :sub_agent)
      child.buffer.put(type: :response, origin: :session_manager, content: 'x')

      expect(reg.replay_tail_for_job(child.id)).to eq([])
    end
  end

  describe '#any_job_has_session_state? (issue #548)' do
    def harness_with_session(non_empty)
      h = Object.new
      sess = Object.new
      sess.define_singleton_method(:empty?) { !non_empty }
      h.define_singleton_method(:session) { sess }
      h
    end

    it 'is false when no job has a harness (a bare registry)' do
      registry.add_job(kind: :main)

      expect(registry.any_job_has_session_state?).to be(false)
    end

    it 'is false when the only job harness has an empty chain' do
      registry.add_job(kind: :main, harness: harness_with_session(false))

      expect(registry.any_job_has_session_state?).to be(false)
    end

    it 'is true when a NON-foreground job accumulated a conversation' do
      registry.add_job(kind: :main, harness: harness_with_session(false))
      registry.add_job(kind: :sub_agent, harness: harness_with_session(true))
      registry.foreground = 0 # foreground stays the empty main job

      expect(registry.any_job_has_session_state?).to be(true)
    end

    it 'ignores a job the run never drove (harness nil)' do
      registry.add_job(kind: :main, harness: harness_with_session(true))
      registry.add_job(kind: :timed) # no harness - nothing to save

      expect(registry.any_job_has_session_state?).to be(true)
    end
  end

  # issue #548 F: the registry can ask a job to persist its own chain; it never
  # reads a running chain itself.
  describe '#request_save (issue #548 F)' do
    def recording_harness
      h = Object.new
      h.instance_variable_set(:@hits, 0)
      h.define_singleton_method(:request_save) { @hits += 1 }
      h.define_singleton_method(:hits) { @hits }
      h
    end

    it 'routes the request to the job own agent' do
      harness = recording_harness
      job = registry.add_job(kind: :sub_agent, harness: harness)

      expect(registry.request_save(job.id)).not_to be_nil
      expect(harness.hits).to eq(1)
    end

    it 'returns nil for an id that names no job' do
      expect(registry.request_save(99)).to be_nil
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
