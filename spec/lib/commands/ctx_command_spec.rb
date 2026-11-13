# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/ctx_command'

RSpec.describe Commands::CtxCommand do
  def run_command(usage, args = '')
    harness = Object.new
    harness.define_singleton_method(:context_usage) { usage }
    stdout = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  # Split a markdown table row (`| a | b |`) into its cells (the same helper the
  # other :table specs use). This sink has no palette, so the report renders the
  # raw markdown table - the field boundaries survive as real delimiters, which is
  # the point of #474.
  def split_row(line)
    line.strip.sub(/\A\|/, '').sub(/\|\z/, '').split(/\s*\|\s*/).map(&:strip)
  end

  def table_rows(out)
    out.lines.map(&:chomp)
       .select { |l| l.start_with?('|') }
       .reject { |l| l.match?(/\A\| [-| ]+\|\z/) }
       .reject { |l| split_row(l)[0] == 'field' }
       .map { |l| split_row(l) }
  end

  def usage(hash)
    { window: 120_000, tokens: 32_960, estimated: false, pct: 27, headroom: 87_040,
      trigger: 108_000, trigger_pct: 90, due: false }.merge(hash)
  end

  # issue #474, increment 21: the report is the harness' FIELDS, and the padded
  # value column the emitter used to bake is now the gem's column width.
  describe 'the table (issue #474, increment 21)' do
    it 'states each fact as one field/value row' do
      out = run_command(usage({}))

      expect(table_rows(out)).to eq([
        ['Used', '32960 tokens (27% of 120000)'],
        ['Source', 'last LLM response'],
        ['Headroom', '87040 tokens'],
        ['Auto-compact', 'not due (fires at 108000 tokens, 90% of the window)']
      ])
    end

    it 'keeps the title as the heading line above the table' do
      expect(run_command(usage({})).lines.first).to eq("🧠 Context usage\n")
    end

    # The estimate is a fact about which measurement this is, so it is a cell
    # rather than a padded line.
    it 'names the estimate as the source when the number is one' do
      out = run_command(usage({ estimated: true }))

      expect(table_rows(out)).to include(['Source', 'estimate (~4 chars/token)'])
    end

    it 'shows auto-compact as due when the trigger is passed' do
      out = run_command(usage({ due: true }))

      expect(table_rows(out)).to include(
        ['Auto-compact', 'due (fires at 108000 tokens, 90% of the window)']
      )
    end

    # A trigger of nil means nothing fires (no threshold, or a window that cannot
    # hold the reserve), so there is no row to state.
    it 'omits the auto-compact row when no trigger is configured' do
      out = run_command(usage({ trigger: nil, trigger_pct: nil, due: false }))

      expect(table_rows(out)).to eq([
        ['Used', '32960 tokens (27% of 120000)'],
        ['Source', 'last LLM response'],
        ['Headroom', '87040 tokens']
      ])
    end
  end

  # Nothing measured yet is not a table with empty cells: there are no fields, so
  # the answer is the prose note (one :note).
  describe 'with nothing to measure' do
    it 'answers with the prose note and no table' do
      out = run_command(nil)

      expect(out).to eq("  No conversation yet - nothing to measure.\n")
      expect(out.lines.count).to eq(1)
    end
  end

  # The report's fields come from Harness#context_usage, so the command must not
  # invent a row the harness did not measure.
  it 'reads nothing but the harness fields' do
    usage = { window: 65_536, tokens: 42_133, estimated: false, pct: 64,
              headroom: 23_403, trigger: 57_344, trigger_pct: 88, due: false }

    expect(table_rows(run_command(usage))).to eq([
      ['Used', '42133 tokens (64% of 65536)'],
      ['Source', 'last LLM response'],
      ['Headroom', '23403 tokens'],
      ['Auto-compact', 'not due (fires at 57344 tokens, 88% of the window)']
    ])
  end

  it 'ignores its arguments' do
    expect(table_rows(run_command(usage({}), '-v extra'))).to eq(
      table_rows(run_command(usage({})))
    )
  end

  it 'declares its HELP entry in the session group' do
    help = described_class::HELP

    expect(help.usage).to eq('ctx')
    expect(help.group).to eq(:session)
    expect(help.see_also).to include('compact', 'session')
  end
end
