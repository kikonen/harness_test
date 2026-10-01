# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/reasoning_command'

# issue #98: /reasoning shows the reasoning text of the last response, which
# is otherwise only visible in .harness/sessions/<session-id>/harness.log.
RSpec.describe Commands::ReasoningCommand do
  let(:session) { Session.new('system prompt') }

  # A minimal stand-in for Harness providing only what the command uses.
  let(:harness) do
    Class.new do
      attr_reader :session

      def initialize(session)
        @session = session
      end
    end.new(session)
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

  it 'prints the reasoning of the last response' do
    session.record_reasoning("Let me think about this step by step.\nFirst, check the file.")

    out = run_command

    expect(out).to include('Reasoning for the last response')
    expect(out).to include('Let me think about this step by step.')
    expect(out).to include('First, check the file.')
  end

  it 'reports no reasoning when the model did not return any' do
    expect(run_command).to match(/No reasoning to show yet/)
  end

  it 'treats empty or whitespace-only reasoning as absent' do
    session.record_reasoning('   ')

    expect(run_command).to match(/No reasoning to show yet/)
  end

  it 'clears the stored reasoning when the session is cleared' do
    session.record_reasoning('some thinking')
    session.clear

    expect(session.last_reasoning).to be_nil
  end
end
