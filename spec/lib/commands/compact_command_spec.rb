# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/compact_command'

# issue #70: /compact must report the resulting context size so the user can
# verify that compaction freed space without burning tokens on a follow-up.
RSpec.describe Commands::CompactCommand do
  let(:session) { Session.new('system prompt') }
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
  let(:harness) do
    Class.new do
      attr_accessor :session, :session_manager

      def initialize(session, manager)
        @session         = session
        @session_manager = manager
      end
    end.new(session, manager)
  end

  # Commands write to an explicit stream (TUI-ready), so the spec supplies a
  # StringIO and reads it back instead of swapping $stdout.
  def run_command
    io      = StringIO.new
    command = described_class.new(harness:, file_list: nil, options: nil, ui: UI::Console.new(stdout: io))
    command.handle('')
    io.string
  end

  it 'prints the resulting context size after compaction' do
    out = run_command

    expect(out).to match(
      /Session compacted: 10 messages -> 4 messages \(2 recent retained\)\.\n  🧠 ctx ~62100\/65536 \(95%\) -> 🧠 ctx ~523\/65536 \(1%\)\n\nSummary:\nsummary text\n/
    )
  end

  it 'omits the context line when before or after is missing' do
    result[:context_before] = nil

    expect(run_command).not_to match(/🧠 ctx/)

    result[:context_before] = '🧠 ctx ~62100/65536 (95%)'
    result[:context_line]   = nil

    expect(run_command).not_to match(/🧠 ctx/)
  end
end
