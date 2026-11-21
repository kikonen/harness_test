# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'job_registry'
require 'session_locator'
require 'system_settings'
require 'system_record'
require 'system_saver'

# SystemSaver is the system's owner-built writer: the CLI hands it its own
# registry so a per-Harness SessionManager never assembles a file it does not
# own. These are the seam's own guarantees (the layered WRITE shapes are covered
# in system_record_spec.rb, the whole-run save in cli_spec.rb).
RSpec.describe SystemSaver do
  def harness_double(settings)
    Object.new.tap do |h|
      h.define_singleton_method(:settings) { settings }
      h.define_singleton_method(:mcp_connected_summary) { [] }
    end
  end

  def session_h(id, workdir)
    {
      version: 1,
      session_id: id,
      created_at: '2026-01-01T00:00:00+00:00',
      workdir:,
      Session::FILE_CACHE_KEY => {},
      access: { both: [], read: [], write: [], delete: [] }
    }
  end

  describe 'the registry seam' do
    it 'holds the registry it was built from (the CLI reads it back)' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)

      expect(described_class.new(SessionLocator.new('dir'), registry).registry).to be(registry)
    end

    # The saved foreground is the registry's fact, read live: #548 moved it off a
    # per-Harness object onto the object that owns the registry.
    it 'reports the foreground job the registry holds at read time' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)
      saver = described_class.new(SessionLocator.new('dir'), registry)

      expect(saver.foreground_job).to eq(main.id)
      registry.foreground = other.id
      expect(saver.foreground_job).to eq(other.id)
    end
  end

  describe 'the saved job list a resume needs (issue #548)' do
    it 're-resolves the ids a save wrote against a resumed registry (dangling ids dropped)' do
      Dir.mktmpdir do |dir|
        id      = 'c0c0c0c0-0000-0000-0000-000000000000'
        locator = SessionLocator.new(dir)
        registry = JobRegistry.new
        registry.add_job(kind: :main)
        registry.add_job(kind: :sub_agent)
        registry.add_job(kind: :timed)

        saver = described_class.new(locator, registry)
        saver.write_system_files(id, session_h(id, dir), harness_double(SystemSettings.from_options({})))
        # Read the record back the way a resume does: JSON gives Strings for the
        # kind/status Symbols a save wrote.
        saved = locator.read_system(id)[:jobs]
        expect(saved[1][:kind]).to eq('sub_agent')

        # A resumed registry has rebuilt only the main turn and one job: the
        # third saved id names a job this run does not have.
        resumed = JobRegistry.new
        resumed.add_job(kind: :main)
        resumed.add_job(kind: :command)
        saver = described_class.new(locator, resumed)

        expect(saver.resumable_job_ids(saved)).to eq([0, 1])
      end
    end
  end
end
