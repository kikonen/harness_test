# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/exit_command'

RSpec.describe Commands::ExitCommand do
  def build
    described_class.new(harness: nil, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: StringIO.new))
  end

  # CommandHandler#dispatch decides to leave the loop through this flag
  # (respond_to?(:exited?) && cmd.exited?), so a fresh command must report
  # "not exited" rather than nil-vs-false ambiguity or a raised NoMethodError.
  it 'is not exited before handle runs' do
    expect(build.exited?).to be_falsey
  end

  it 'reports exited after handle runs' do
    cmd = build
    cmd.handle('')

    expect(cmd.exited?).to be true
  end

  it 'prints nothing on the way out' do
    stdout = StringIO.new
    cmd = described_class.new(harness: nil, file_list: nil, options: nil,
                              ui: UI::Console.new(stdout: stdout))
    cmd.handle('')

    expect(stdout.string).to eq('')
  end

  it 'ignores its arguments (the exit is unconditional)' do
    cmd = build
    cmd.handle('now')

    expect(cmd.exited?).to be true
  end

  it 'declares its HELP entry in the general group' do
    help = described_class::HELP

    expect(help.usage).to eq('exit')
    expect(help.group).to eq(:general)
    expect(help.see_also).to eq(%w[save help])
  end
end
