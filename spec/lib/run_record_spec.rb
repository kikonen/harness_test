# frozen_string_literal: true

require 'spec_helper'
require 'job_registry'
require 'run_record'

# #548 increment 1: RunRecord is the run-owned persistence half the CLI injects
# into SessionManager in place of the raw JobRegistry, so a per-Harness save
# reads only the two run keys (foreground job, replay tail) and never the
# scheduling registry itself.
RSpec.describe RunRecord do
  def registry_with_tail(tail)
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    registry.foreground_buffer.restore(tail)
    registry
  end

  it 'reports the foreground job id the registry holds at read time' do
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    node = registry.add_job(kind: :command, requested_by: registry.jobs.first)
    registry.foreground = node.id

    expect(described_class.new(registry).foreground_job).to eq(node.id)
  end

  # The keys are read live, not snapshotted when RunRecord is built: a run adds
  # jobs and switches the foreground after CLI#setup, and the save must record
  # the registry as it is at save time.
  it 'reads the registry live, not a snapshot taken at construction' do
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    record = described_class.new(registry)

    expect(record.foreground_job).to eq(0)

    node = registry.add_job(kind: :command, requested_by: registry.jobs.first)
    registry.foreground = node.id

    expect(record.foreground_job).to eq(node.id)
  end

  it 'supplies the foreground buffer replay tail (the JobRegistry save shape)' do
    tail = [{ type: 'user', origin: 'user', content: 'do the thing' }]
    registry = registry_with_tail(tail)

    expect(described_class.new(registry).replay_tail).to eq(
      registry.replay_tail_for_save
    )
  end

  it 'returns an empty tail when the disabled window records nothing' do
    registry = JobRegistry.new(max_saved: 0)
    registry.add_job(kind: :main)

    expect(described_class.new(registry).replay_tail).to eq([])
  end
  # issue #548 increment 2: the writer persists the run -> job map and the next
  # job id. next_id is read live so a resumed run continues numbering.
  it 'reports next_id so a resumed run never reuses a job id' do
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    registry.add_job(kind: :command)

    expect(described_class.new(registry).next_id).to eq(2)
  end

  it 'serializes each retained job with edges as IDS, not live Job refs' do
    registry = JobRegistry.new
    main = registry.add_job(kind: :main)
    registry.add_job(kind: :command, requested_by: main, dependencies: [main])

    jobs = described_class.new(registry).jobs_for_save

    expect(jobs.map { |j| j[:id] }).to eq([0, 1])
    expect(jobs[0][:kind]).to eq(:main)
    expect(jobs[1][:requested_by]).to eq(main.id)        # id, not a Job object
    expect(jobs[1][:dependencies]).to eq([main.id])      # ids, not Job objects
    expect(jobs[1][:dir]).to eq('jobs/1')
  end

  # A dependency that is a callable predicate (not a Job) has no id to record;
  # it is omitted (its re-resolution belongs to increment 4).
  it 'omits a non-Job dependency that has no id' do
    registry = JobRegistry.new
    registry.add_job(kind: :timed, dependencies: [-> { true }])

    expect(described_class.new(registry).jobs_for_save.first[:dependencies]).to eq([])
  end
end
