# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/session_command'

RSpec.describe Commands::SessionCommand do
  def run_command(summary)
    session = Object.new
    session.define_singleton_method(:summary) { summary }
    harness = Object.new
    harness.define_singleton_method(:session) { session }
    stdout = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle('')
    stdout.string
  end

  it 'prints the session summary verbatim' do
    summary = "Session abc12345: 12 user, 9 assistant messages\n"

    expect(run_command(summary)).to eq(summary)
  end

  # The summary is built by Session#summary (id, counts, prompts, stats);
  # adding a line here would make /session disagree with what /save reports.
  it 'adds nothing around the summary' do
    expect(run_command('one line')).to eq("one line\n")
  end

  it 'prints nothing when the summary is empty' do
    expect(run_command('')).to eq("\n")
  end

  it 'ignores its arguments' do
    expect(run_command('summary')).to eq("summary\n")
  end

  it 'declares its HELP entry in the session group' do
    help = described_class::HELP

    expect(help.usage).to eq('session')
    expect(help.group).to eq(:session)
    expect(help.see_also).to include('session-clear', 'ctx')
  end
end
