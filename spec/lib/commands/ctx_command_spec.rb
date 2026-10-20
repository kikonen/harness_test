# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/ctx_command'

RSpec.describe Commands::CtxCommand do
  def run_command(report)
    harness = Object.new
    harness.define_singleton_method(:context_report) { report }
    stdout = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle('')
    stdout.string
  end

  it 'prints the harness context report verbatim' do
    report = "Context: 12 000 / 65 536 tokens (18%)\n"

    expect(run_command(report)).to include(report)
  end

  it 'follows the report with a blank line' do
    expect(run_command('one line')).to eq("one line\n\n")
  end

  # The report is a single string built by Harness#context_report; the command
  # must not add its own header, or /ctx and auto-compact wording drift apart.
  it 'prints only the separator when the report is empty' do
    expect(run_command('')).to eq("\n\n")
  end

  it 'ignores its arguments' do
    harness = Object.new
    harness.define_singleton_method(:context_report) { 'report' }
    stdout = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle('-v extra')

    expect(stdout.string).to eq("report\n\n")
  end

  it 'declares its HELP entry in the session group' do
    help = described_class::HELP

    expect(help.usage).to eq('ctx')
    expect(help.group).to eq(:session)
    expect(help.see_also).to include('compact', 'session')
  end
end
