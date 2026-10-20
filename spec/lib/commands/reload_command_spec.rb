# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/reload_command'

RSpec.describe Commands::ReloadCommand do
  def run_command
    reloaded = 0
    manager = Object.new
    manager.define_singleton_method(:reload_rules) { reloaded += 1 }
    harness = Object.new
    harness.define_singleton_method(:session_manager) { manager }
    stdout = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle('')
    [stdout.string, reloaded]
  end

  it 're-reads the rules exactly once' do
    _out, reloaded = run_command

    expect(reloaded).to eq(1)
  end

  it 'confirms which two sources were re-read' do
    out, _ = run_command

    expect(out).to include('System prompt reloaded')
    expect(out).to include('base prompt file')
    expect(out).to include('harness.md project rules')
  end

  it 'ends with a blank line' do
    out, _ = run_command

    expect(out.end_with?("\n\n")).to be true
  end

  it 'propagates a reload failure instead of printing a false confirmation' do
    manager = Object.new
    manager.define_singleton_method(:reload_rules) { raise HarnessError, 'prompt file missing' }
    harness = Object.new
    harness.define_singleton_method(:session_manager) { manager }
    cmd = described_class.new(harness: harness, file_list: nil, options: nil,
                              ui: UI::Console.new(stdout: StringIO.new))

    expect { cmd.handle('') }.to raise_error(HarnessError, /prompt file missing/)
  end

  it 'declares its HELP entry in the session group' do
    help = described_class::HELP

    expect(help.usage).to eq('reload')
    expect(help.group).to eq(:session)
  end
end
