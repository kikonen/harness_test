# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'fileutils'
require 'tmpdir'
require 'commands/resume_command'

# issue #280: mid-run /resume is DELEGATED, not performed here. The command
# hands the id to the run's own setup action (CLI#setup) and reports the
# Harness that action built - never the (now stale) harness this command was
# constructed with.
RSpec.describe Commands::ResumeCommand do
  let(:workdir) { Dir.mktmpdir('resume-cmd-spec') }
  let(:file_list) { FileList.new([], workdir: workdir) }
  let(:options) { { model: 'test-model' } }

  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  def build_command(on_resume: nil, harness: nil)
    io      = StringIO.new
    command = described_class.new(harness: harness, file_list: file_list,
                                  options: options, ui: UI::Console.new(stdout: io),
                                  on_resume: on_resume)
    [command, io]
  end

  # Stand-in for the fresh Harness CLI#setup builds: only its session id is
  # reported by the command.
  def fake_harness(id)
    double('harness', session: double('session', session_id: id))
  end

  it 'prints usage when no id is given' do
    command, io = build_command

    command.handle('')

    expect(io.string).to include('Usage: /resume <id>')
  end

  it 'reports an error when the run has no setup action to delegate to' do
    command, io = build_command(harness: fake_harness('a' * 8))

    command.handle('f7931611')

    expect(io.string).to include('[error] resume is not available in this run')
  end

  it 'calls the setup action with the id and reports the id of the harness IT built' do
    seen = nil
    fresh = fake_harness('f7931611-30b4-4b4b-aec6-f7083ef2942a')
    command, io = build_command(
      # The replaced run's harness: deliberately a DIFFERENT id, so the
      # reported one can only have come from the action's return value.
      harness: fake_harness('ffffffff-1111-1111-1111-111111111111'),
      on_resume: ->(id) { seen = id; fresh }
    )

    command.handle('f7931611-30b4-4b4b-aec6-f7083ef2942a')

    expect(seen).to eq('f7931611-30b4-4b4b-aec6-f7083ef2942a')
    expect(io.string).to include('Session f7931611-30b4-4b4b-aec6-f7083ef2942a resumed.')
    expect(io.string).to include('rebuilt under it')
    expect(io.string).not_to include('ffffffff-1111-1111-1111-111111111111')
  end

  it 'does nothing when the setup action raises (the run keeps its own state)' do
    command, io = build_command(
      harness: fake_harness('ffffffff-1111-1111-1111-111111111111'),
      on_resume: ->(_id) { raise HarnessError, "no saved session matching 'deadbeef'" }
    )

    expect {
      begin
        command.handle('deadbeef')
      rescue HarnessError
        # CLI#run reports this line; the command itself must not half-resume.
      end
    }.not_to raise_error

    expect(io.string).not_to include('resumed')
  end

  describe '#resume_cli_string' do
    it 'builds the startup resume command for this model and workdir' do
      command, = build_command

      line = command.resume_cli_string('f7931611')

      expect(line).to include('ruby harness.rb')
      expect(line).to include('-m test-model')
      expect(line).to include('--resume f7931611')
      expect(line).to include("-d #{workdir}")
    end
  end
end
