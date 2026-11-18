# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'cli'
require 'commands/models_command'
require 'system_settings'

# /models reads EVERY model fact - the catalogue (model_profiles, default_model)
# and the active-model name - off @settings, plus options[:base_url] for the
# empty case. It reaches nothing through harness (#286).
RSpec.describe Commands::ModelsCommand do
  # A real SystemSettings (what models_command gets at runtime): the catalogue,
  # the active name, plus the palette/width main_thread_renderer needs.
  def settings(profiles:, active:, default: nil)
    SystemSettings.from_options(
      model_profiles: profiles, active_model: active, default_model: default)
  end

  def run_command(settings, options: { base_url: 'http://cfg:11434/v1' })
    io = StringIO.new
    described_class.new(file_list: nil, options: options,
                        settings: settings,
                        ui: UI::Console.new(stdout: io)).handle('')
    io.string
  end

  it 'lists every profile with its model, endpoint and API type' do
    profiles = [{ name: 'qwen', model: 'qwen3:8b', url: 'http://a:11434/v1' },
                { name: 'remote', model: 'gpt-x', url: 'https://b/v1', api: 'openai' }]
    out = run_command(settings(profiles: profiles, active: 'qwen'))

    expect(out).to include('Configured models (2):')
    expect(out).to include('qwen  ->  qwen3:8b @ http://a:11434/v1 (openai)')
    expect(out).to include('remote  ->  gpt-x @ https://b/v1 (openai)')
  end

  # issue #217: the API tag is the whole point - it says which endpoint shape a
  # profile hits, and ollama is the one that honours num_ctx.
  it 'tags an ollama profile as ollama' do
    out = run_command(settings(profiles: [{ name: 'loc', model: 'qwen3:8b', api: 'ollama' }],
                               active: 'loc'))

    expect(out).to include('loc  ->  qwen3:8b @ ')
    expect(out).to include('(ollama)')
  end

  it 'marks the default profile and the active one, together when both apply' do
    out = run_command(settings(
      profiles: [{ name: 'qwen', model: 'qwen3:8b' }, { name: 'other', model: 'gpt-x' }],
      active: 'qwen', default: 'qwen'))

    expect(out).to include('[default, active]')
    other = out.lines.find { |l| l.include?('gpt-x') }
    expect(other).to include('other  ->  gpt-x @')
    expect(other).not_to include('[')
  end

  it 'marks a profile default by its model name when the label differs' do
    out = run_command(settings(profiles: [{ name: 'lab', model: 'qwen3:8b' }],
                               active: 'other', default: 'qwen3:8b'))

    expect(out).to include('lab  ->  qwen3:8b @ ')
    expect(out).to include('[default]')
  end

  it 'ends with the switch hint naming the current model' do
    out = run_command(settings(profiles: [{ name: 'qwen', model: 'qwen3:8b' }], active: 'qwen'))

    expect(out).to include('Switch with: /model <name>   (current: qwen)')
  end

  # issue #449: vision is per-profile, so /models says which model a tool-result
  # image could actually be sent to (and stays silent for one that cannot).
  it 'tags a vision profile and leaves a text profile untagged' do
    out = run_command(settings(
      profiles: [{ name: 'eyes', model: 'vis', vision: true },
                 { name: 'plain', model: 'qwen', vision: false }],
      active: 'plain'))

    expect(out.lines.find { |l| l.include?('eyes') }).to include('[vision]')
    expect(out.lines.find { |l| l.include?('plain') }).not_to include('[vision]')
  end

  # A profile with no url falls back to the CLI default endpoint rather than
  # printing an empty host.
  it 'falls back to CLIOptions::DEFAULT_BASE_URL when a profile has no url' do
    out = run_command(settings(profiles: [{ name: 'qwen', model: 'qwen3:8b' }], active: 'qwen'))

    expect(out).to include("@ #{CLIOptions::DEFAULT_BASE_URL}")
  end

  describe 'with no profiles configured' do
    it 'says so and reports the current model with the configured base url' do
      out = run_command(settings(profiles: [], active: 'fallback-model'))

      expect(out).to include('No model profiles configured.')
      expect(out).to include('Current model: fallback-model (@ http://cfg:11434/v1)')
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
