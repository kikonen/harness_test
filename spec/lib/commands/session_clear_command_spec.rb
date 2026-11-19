# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'job_registry'
require 'commands/session_clear_command'

RSpec.describe Commands::SessionClearCommand do
  def run_command
    cleared = 0
    session = Object.new
    session.define_singleton_method(:clear) { cleared += 1 }
    harness = Object.new
    harness.define_singleton_method(:session) { session }
    stdout = StringIO.new
    registry = JobRegistry.new
    registry.add_job(kind: :main, harness:)
    described_class.new(registry:, file_list: nil,
                        ui: UI::Console.new(stdout: stdout)).handle('')
    [stdout.string, cleared]
  end

  # /clear (access grants) and /session-clear (conversation) are different
  # lists; this one must reset the session and say so, nothing else.
  it 'clears the conversation exactly once' do
    _out, cleared = run_command

    expect(cleared).to eq(1)
  end

  it 'says the history was reset, not the saved file' do
    out, _ = run_command

    expect(out).to include('Session cleared')
    expect(out).to include('conversation history reset')
    expect(out).not_to include('file')
  end

  it 'propagates a session failure rather than confirming a clear that never happened' do
    session = Object.new
    session.define_singleton_method(:clear) { raise HarnessError, 'session locked' }
    harness = Object.new
    harness.define_singleton_method(:session) { session }
    registry = JobRegistry.new
    registry.add_job(kind: :main, harness:)
    cmd = described_class.new(registry:, file_list: nil,
                              ui: UI::Console.new(stdout: StringIO.new))

    expect { cmd.handle('') }.to raise_error(HarnessError, /session locked/)
  end

  it 'declares its HELP entry in the session group' do
    help = described_class::HELP

    expect(help.usage).to eq('session-clear')
    expect(help.group).to eq(:session)
    expect(help.see_also).to include('session')
  end
end
