# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/models_command'
require 'system_settings'

# /models reads EVERY model fact - the catalogue (model_profiles, default_profile_id)
# and the active-model name - off @settings. It reaches nothing through harness
# and knows no per-connection endpoint: a profile's url is the only endpoint a
# listing shows, and there is no built-in default to fabricate (#286).
RSpec.describe Commands::ModelsCommand do
  # A real SystemSettings (what models_command gets at runtime): the catalogue,
  # the active name, plus the palette/width main_thread_renderer needs.
  def settings(profiles:, active:, default: nil)
    SystemSettings.from_options(
      model_profiles: profiles, active_profile_id: active, default_profile_id: default)
  end

  # A run always has a palette (SystemSettings#output_palette is never nil), so
  # the listing renders as kramdown's box table. Strip the ANSI runs, drop the
  # rule rows, and split a `│ a │ b │` row into cells: the field boundaries
  # survive as real delimiters (#474), so a column is read BY NAME via the
  # header rather than from a fused row string. Cell text is exact: no cell here
  # is wide enough for the gem to wrap it.
  def table_rows(out)
    out.gsub(/\e\[[0-9;]*m/, '').lines.map(&:chomp)
       .grep(/\A\s*│/).map { |l| l.split('│', -1)[1..-2].map(&:strip) }
  end

  def run_command(settings)
    io = StringIO.new
    described_class.new(file_list: nil,
                        settings: settings,
                        ui: UI::Console.new(stdout: io)).handle('')
    io.string
  end

  # The listing is a :table (#474): each fact is its own named column - name, id
  # and the model sent to the endpoint (#572) never fused into one row.
  it 'lists every profile as a table with name, id, model, endpoint and API columns' do
    profiles = [{ name: 'qwen', url: 'http://a:11434/v1', model: 'qwen-model' },
                { name: 'remote', url: 'https://b/v1', api: 'openai', model: 'remote-model' }]
    out = run_command(settings(profiles: profiles, active: 'qwen'))
    rows = table_rows(out)

    expect(out).to include('Configured models (2):')
    expect(rows.first)
      .to eq(%w[name id model url api flags])
    expect(rows[1])
      .to eq(['qwen', 'qwen', 'qwen-model', 'http://a:11434/v1', 'openai', 'active'])
    expect(rows[2])
      .to eq(['remote', 'remote', 'remote-model', 'https://b/v1', 'openai', ''])
  end

  # issue #217: the API tag is the whole point - it says which endpoint shape a
  # profile hits, and ollama is the one that honours num_ctx. It is its own column.
  it 'tags an ollama profile as ollama' do
    out = run_command(settings(
      profiles: [{ name: 'loc', api: 'ollama', model: 'loc-model' }], active: 'loc'))

    expect(table_rows(out)[1])
      .to eq(['loc', 'loc', 'loc-model', '', 'ollama', 'active'])
  end

  it 'marks the default profile and the active one, together when both apply' do
    out = run_command(settings(
      profiles: [{ name: 'qwen', id: 'qwen', model: 'qwen-model' },
                 { name: 'other', id: 'other', model: 'other-model' }],
      active: 'qwen', default: 'qwen'))

    expect(table_rows(out)[1])
      .to eq(['qwen', 'qwen', 'qwen-model', '', 'openai', 'default, active'])
    expect(table_rows(out)[2])
      .to eq(['other', 'other', 'other-model', '', 'openai', ''])
  end

  it 'ends with the switch hint naming the current model' do
    out = run_command(settings(
      profiles: [{ name: 'qwen', id: 'qwen', model: 'qwen-model' }], active: 'qwen'))

    expect(out).to include('Switch with: /model <id>   (current: qwen)')
  end

  # issue #449: vision is per-profile, so /models says which model a tool-result
  # image could actually be sent to (and stays silent for one that cannot).
  it 'tags a vision profile and leaves a text profile untagged' do
    out = run_command(settings(
      profiles: [{ name: 'eyes', vision: true, model: 'eyes-model' },
                 { name: 'plain', vision: false, model: 'plain-model' }],
      active: 'plain'))

    rows = table_rows(out)
    expect(rows[1]).to eq(['eyes', 'eyes', 'eyes-model', '', 'openai', 'vision'])
    expect(rows[2]).to eq(['plain', 'plain', 'plain-model', '', 'openai', 'active'])
  end

  # A profile with no url in a run that has other profiles lists with no
  # endpoint, not a fabricated default host.
  it 'lists a profile with no url without inventing an endpoint' do
    out = run_command(settings(
      profiles: [{ name: 'qwen', id: 'qwen', model: 'qwen-model' }], active: 'qwen'))

    expect(out).not_to include('localhost')
    expect(table_rows(out)[1])
      .to eq(['qwen', 'qwen', 'qwen-model', '', 'openai', 'active'])
  end

  describe 'with no profiles configured' do
    it 'says so and names the current model (no endpoint is known)' do
      out = run_command(settings(profiles: [], active: 'fallback-model'))

      expect(out).to include('No model profiles configured.')
      expect(out).to include('Current model: fallback-model')
      expect(out).not_to include('http://')
    end

    it 'prints no listing header' do
      expect(run_command(settings(profiles: [], active: 'm')))
        .not_to include('Configured models')
    end
  end

  it 'declares its HELP entry' do
    help = described_class::HELP
    expect(help.usage).to eq('models')
    expect(help.group).to eq(:model)
    expect(help.see_also).to eq(%w[model param])
  end
end
