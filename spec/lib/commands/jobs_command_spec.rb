# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'job_registry'
require 'harness'
require 'harness_factory'
require 'system_settings'
require 'session_locator'
require 'commands/jobs_command'

# /jobs (issue #286): the registry owns the flat list, so the command reports it
# as DATA through UI::Renderer - the row shape is the renderer's, and the switch
# goes through the registry's own guard.
# /jobs add (issue #548): the command builds the agent through the run's
# HarnessFactory - the same call the CLI used for the main turn, with only
# `kind` changed - and never assembles a Harness itself.
# NAME_RUN_ID: a top-level constant is global across the suite, and
# harness_factory_spec.rb defines its own SESSION_ID with the same value.
NAME_RUN_ID = 'aaaaaaaa-0000-0000-0000-000000000000'

RSpec.describe Commands::JobsCommand do
  def run(args, registry)
    io = StringIO.new
    described_class.new(registry:, file_list: nil,
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
      described_class.new(file_list: nil,
                          ui: UI::Console.new(stdout: io)).handle('')

      expect(io.string).to include('No registry')
    end
  end

  # /jobs add (issue #548): the command builds the agent through the run's
  # HarnessFactory - the same call the CLI used for the main turn, with only
  # `kind` changed - and never assembles a Harness itself.
  describe '/jobs add' do
    before { allow_any_instance_of(SandboxGemfile).to receive(:lock_seeded?).and_return(true) }

    # The harness sandbox's own tree as workdir: the harness's real
    # Gemfile/Gemfile.lock are there, so a Harness built over it reaches the
    # same sandbox state a real run of this project has.
    # Nothing is written here: no save runs, and the sandbox Gemfile is gitignored.
    def add_run(extra = {})
      workdir   = File.expand_path(File.join(__dir__, '../../..'))
      registry  = JobRegistry.new
      factory   = HarnessFactory.new(
        registry:,
        locator: SessionLocator.new(workdir),
        settings: SystemSettings.from_options({}),
        file_list: FileList.new([], workdir: workdir),
        system_saver: SystemSaver.new(SessionLocator.new(workdir), registry),
        logger: nil)
      main = factory.add_harness_job(kind: :main, session_id: NAME_RUN_ID)
      io = StringIO.new
      command = described_class.new(
        registry:, file_list: nil, ui: UI::Console.new(stdout: io),
        harness_factory: factory, session_id: NAME_RUN_ID, **extra)
      [command, io, registry, main]
    end

    it 'adds a real Harness-backed job and makes it foreground' do
      command, io, registry, main = add_run
      command.handle('add')

      added = registry.job(1)
      expect(added.kind).to eq(:sub_agent)
      expect(added.harness).to be_a(Harness)
      expect(added.harness).not_to be(main.harness)
      expect(added.harness.session_manager.job_id).to eq(1)
      expect(registry.foreground).to eq(1)
      expect(added.requested_by).to be(main)
      expect(io.string).to include('job #1 (sub_agent) added')
      rows = data_rows(io.string).map { |l| split_row(l) }
      expect(rows).to eq([['', '#0', 'main', 'pending'],
                          ['*', '#1', 'sub_agent', 'pending']])
    end

    # The record must land in the NEW job's own buffer (the one a resume redraws
    # for that job), not in the main job's buffer that happened to be foreground
    # before the switch.
    it 'records a prompt given with add into the new job buffer' do
      command, _io, registry, _main = add_run
      command.handle('add sub_agent do the thing')

      expect(registry.job(1).buffer.tail.map(&:content))
        .to include('sub_agent do the thing')
      expect(registry.job(0).buffer.tail.map(&:content))
        .not_to include('sub_agent do the thing')
    end
    # 'sub_agent' is the form word, so it is consumed rather than remembered:
    # switching to the new job records that very submit line into its buffer, and
    # a kept word would store the usage twice.
    it 'consumes the kind word instead of recording it as the prompt' do
      command, _io, registry, _main = add_run
      command.handle('add sub_agent')

      expect(registry.job(1).buffer.tail.map(&:content))
        .not_to include('sub_agent')
    end

  end

  # The short form of a switch (the owner's request): a bare id as the first word
  # is the job to make foreground, so switching takes /jobs 1 rather than
  # /jobs switch 1. The words still win, so a word is never read as an id.
  describe 'the bare-id short form' do
    it 'switches to an id given without the switch word' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)
      other = registry.add_job(kind: :sub_agent, requested_by: registry.job(0))

      out = run('1', registry)

      expect(registry.foreground).to eq(other.id)
      expect(out).to include('foreground job is now #1')
    end

    it 'accepts the id in the list form too (/jobs #1)' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)
      registry.add_job(kind: :sub_agent, requested_by: registry.job(0))

      run('#1', registry)

      expect(registry.foreground).to eq(1)
    end

    it 'names an id it does not retain instead of switching' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)

      out = run('99', registry)

      expect(registry.foreground).to eq(0)
      expect(out).to include('job #99 is not retained')
    end

    # A word is a word: /jobs bogus (and a bare /jobs) is still the list report,
    # not a switch to a job nothing names.
    it 'lists when the first word is not an id' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)

      out = run('bogus', registry)

      expect(registry.foreground).to eq(0)
      expect(out).to include('Jobs (foreground marked *)')
    end
  end
end
