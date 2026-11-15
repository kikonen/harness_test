# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'job_registry'
require 'commands/jobs_command'

# /jobs (issue #286): the registry owns the flat list, so the command reports it
# as DATA through UI::Renderer - the row shape is the renderer's, and the switch
# goes through the registry's own guard.
RSpec.describe Commands::JobsCommand do
  def run(args, registry)
    io = StringIO.new
    h = Object.new
    h.define_singleton_method(:registry) { registry }
    described_class.new(harness: h, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: io)).handle(args)
    io.string
  end

  def split_row(line)
    line.strip.sub(/\A\|/, '').sub(/\|\z/, '').split(/\s*\|\s*/).map(&:strip)
  end

  def data_rows(out)
    out.lines.map(&:chomp)
       .select { |l| l.start_with?('|') }
       .reject { |l| l.match?(/\A\| [-| ]+\|\z/) }
       .reject { |l| split_row(l)[0] == 'mark' }
  end

  describe 'the flat-list report' do
    it 'lists every retained job and marks the foreground one' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      registry.add_job(kind: :command, requested_by: main)

      out = run('', registry)
      rows = data_rows(out).map { |l| split_row(l) }

      expect(rows).to eq([['*', '#0', 'main', 'pending'], ['', '#1', 'command', 'pending']])
    end

    it 'marks the job the foreground now points at' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)
      registry.foreground = other.id

      rows = data_rows(run('', registry)).map { |l| split_row(l) }

      expect(rows).to eq([['', '#0', 'main', 'pending'], ['*', '#1', 'command', 'pending']])
    end

    it 'reports the help usage for a bare switch (no id given)' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)

      expect(run('switch', registry)).to include('jobs switch <id>')
    end
  end

  describe 'switching the foreground job' do
    it 'moves the foreground to a retained id' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)

      out = run("switch #{other.id}", registry)

      expect(registry.foreground).to eq(other.id)
      expect(out).to include('foreground job is now #1')
    end

    # A dropped job has no buffer to show, so the registry's guard is what the
    # command reports - the command never mutates state by itself.
    it 'reports the registry error for an id it does not retain' do
      registry = JobRegistry.new(tasks_kept: 1)
      fg = registry.add_job(kind: :command)
      dropped = registry.add_job(kind: :command, requested_by: fg)
      dropped.finish
      # The trim only fires once a second finished job fills the kept slot.
      registry.add_job(kind: :command, requested_by: fg).finish

      out = run("switch #{dropped.id}", registry)

      expect(registry.foreground).to eq(fg.id)
      expect(out).to include('not retained')
    end

    it 'says nothing to list when there is no registry' do
      io = StringIO.new
      described_class.new(harness: Object.new, file_list: nil, options: nil,
                          ui: UI::Console.new(stdout: io)).handle('')

      expect(io.string).to include('No registry')
    end
  end
end
