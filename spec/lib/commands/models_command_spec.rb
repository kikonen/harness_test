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

  def run_command(settings)
    io = StringIO.new
    described_class.new(file_list: nil,
                        settings: settings,
                        ui: UI::Console.new(stdout: io)).handle('')
    io.string
  end

  it 'lists every profile with its model name, endpoint and API type' do
    profiles = [{ name: 'qwen', url: 'http://a:11434/v1' },
                { name: 'remote', url: 'https://b/v1', api: 'openai' }]
    out = run_command(settings(profiles: profiles, active: 'qwen'))

    expect(out).to include('Configured models (2):')
    expect(out).to include('qwen  ->  qwen @ http://a:11434/v1 (openai)')
    expect(out).to include('remote  ->  remote @ https://b/v1 (openai)')
  end

  # issue #217: the API tag is the whole point - it says which endpoint shape a
  # profile hits, and ollama is the one that honours num_ctx.
  it 'tags an ollama profile as ollama' do
    out = run_command(settings(profiles: [{ name: 'loc', api: 'ollama' }], active: 'loc'))

    expect(out).to include('loc  ->  loc @ ')
    expect(out).to include('(ollama)')
  end

  it 'marks the default profile and the active one, together when both apply' do
    out = run_command(settings(
      profiles: [{ name: 'qwen', id: 'qwen' }, { name: 'other', id: 'other' }],
      active: 'qwen', default: 'qwen'))

    expect(out).to include('[default, active]')
    other = out.lines.find { |l| l.include?('other') }
    expect(other).to include('other  ->  other @')
    expect(other).not_to include('[')
  end

  it 'ends with the switch hint naming the current model' do
    out = run_command(settings(profiles: [{ name: 'qwen', id: 'qwen' }], active: 'qwen'))

    expect(out).to include('Switch with: /model <id>   (current: qwen)')
  end

  # issue #449: vision is per-profile, so /models says which model a tool-result
  # image could actually be sent to (and stays silent for one that cannot).
  it 'tags a vision profile and leaves a text profile untagged' do
    out = run_command(settings(
      profiles: [{ name: 'eyes', vision: true },
                 { name: 'plain', vision: false }],
      active: 'plain'))

    expect(out.lines.find { |l| l.include?('eyes') }).to include('[vision]')
    expect(out.lines.find { |l| l.include?('plain') }).not_to include('[vision]')
  end

  # A profile with no url in a run that has other profiles lists with no
  # endpoint, not a fabricated default host.
  it 'lists a profile with no url without inventing an endpoint' do
    out = run_command(settings(profiles: [{ name: 'qwen', id: 'qwen' }], active: 'qwen'))

    expect(out).not_to include('localhost')
    expect(out).to include('qwen  ->  qwen @ ')
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
