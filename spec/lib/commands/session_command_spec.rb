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
  # Session#summary now returns structured rows, so /session prints them as a
  # markdown table (raw markdown here - this console has no palette). A table is
  # the DATA form #474 keeps in the buffer, so a browser can re-render it.
  def split_row(line)
    line.strip.sub(/\A\|/, '').sub(/\|\z/, '').split(/\s*\|\s*/).map(&:strip)
  end

  it 'prints the summary as a field/value table' do
    out = run_command([{ field: 'Session id', value: 'abc12345' },
                       { field: 'Messages', value: '12' }])
    lines = out.lines.map(&:chomp)

    expect(split_row(lines[0])).to eq(%w[field value])
    expect(split_row(lines[2])).to eq(['Session id', 'abc12345'])
    expect(split_row(lines[3])).to eq(['Messages', '12'])
  end

  # The summary rows are the data method's, so adding a row here would make
  # /session disagree with what /save reports.
  it 'adds nothing around the summary table' do
    out = run_command([{ field: 'x', value: 'y' }])
    data_rows = out.lines.map(&:chomp)[2..].map { |l| split_row(l) }
    expect(data_rows).to eq([%w[x y]])
  end

  it 'declares its HELP entry in the session group' do
    help = described_class::HELP

    expect(help.usage).to eq('session')
    expect(help.group).to eq(:session)
    expect(help.see_also).to include('session-clear', 'ctx')
  end
end
