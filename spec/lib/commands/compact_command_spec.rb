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

  let(:command) { described_class.new(harness, nil, nil) }

  # Capture $stdout while running the command and return it as a string.
  def run_command
    old_stdout = $stdout
    $stdout    = StringIO.new
    command.handle('')
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  it 'prints the resulting context size after compaction' do
    out = run_command

    expect(out).to match(
      /Session compacted: 10 messages -> 4 messages \(2 recent retained\)\.\n🧠 ctx ~523\/65536 \(1%\)\n\nSummary:\nsummary text\n/
    )
  end

  it 'omits the context line when the manager could not measure usage' do
    result[:context_line] = nil

    expect(run_command).not_to match(/🧠 ctx/)
  end
end
