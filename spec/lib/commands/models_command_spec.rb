# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'cli'
require 'commands/models_command'

# /models reads only harness.session_manager (model_profiles, active_model_name,
# default_model_name) plus options[:base_url] for the empty case.
RSpec.describe Commands::ModelsCommand do
  def session_manager(profiles, active, default: nil)
    sm = Object.new
    sm.define_singleton_method(:model_profiles) { profiles }
    sm.define_singleton_method(:active_model_name) { active }
    sm.define_singleton_method(:default_model_name) { default }
    sm
  end

  def run_command(manager, options: { base_url: 'http://cfg:11434/v1' })
    h = Object.new
    h.define_singleton_method(:session_manager) { manager }
    io = StringIO.new
    described_class.new(harness: h, file_list: nil, options: options,
                        ui: UI::Console.new(stdout: io)).handle('')
    io.string
  end

  it 'lists every profile with its model, endpoint and API type' do
    sm = session_manager(
      [{ name: 'qwen', model: 'qwen3:8b', url: 'http://a:11434/v1' },
       { name: 'remote', model: 'gpt-x', url: 'https://b/v1', api: 'openai' }],
      'qwen'
    )
    out = run_command(sm)

    expect(out).to include('Configured models (2):')
    expect(out).to include('qwen  ->  qwen3:8b @ http://a:11434/v1 (openai)')
    expect(out).to include('remote  ->  gpt-x @ https://b/v1 (openai)')
  end

  # issue #217: the API tag is the whole point - it says which endpoint shape a
  # profile hits, and ollama is the one that honours num_ctx.
  it 'tags an ollama profile as ollama' do
    sm = session_manager([{ name: 'loc', model: 'qwen3:8b', api: 'ollama' }], 'loc')
    expect(run_command(sm)).to include('loc  ->  qwen3:8b @ ')
    expect(run_command(sm)).to include('(ollama)')
  end

  it 'marks the default profile and the active one, together when both apply' do
    sm = session_manager(
      [{ name: 'qwen', model: 'qwen3:8b' }, { name: 'other', model: 'gpt-x' }],
      'qwen', default: 'qwen'
    )
    out = run_command(sm)

    expect(out).to include('[default, active]')
    other = out.lines.find { |l| l.include?('gpt-x') }
    expect(other).to include('other  ->  gpt-x @')
    expect(other).not_to include('[')
  end

  it 'marks a profile default by its model name when the label differs' do
    sm = session_manager([{ name: 'lab', model: 'qwen3:8b' }], 'other', default: 'qwen3:8b')
    expect(run_command(sm)).to include('lab  ->  qwen3:8b @ ')
    expect(run_command(sm)).to include('[default]')
  end

  it 'ends with the switch hint naming the current model' do
    sm = session_manager([{ name: 'qwen', model: 'qwen3:8b' }], 'qwen')
    expect(run_command(sm)).to include('Switch with: /model <name>   (current: qwen)')
  end

  # A profile with no url falls back to the CLI default endpoint rather than
  # printing an empty host.
  it 'falls back to CLI::DEFAULT_BASE_URL when a profile has no url' do
    sm = session_manager([{ name: 'qwen', model: 'qwen3:8b' }], 'qwen')
    expect(run_command(sm)).to include("@ #{CLI::DEFAULT_BASE_URL}")
  end

  describe 'with no profiles configured' do
    it 'says so and reports the current model with the configured base url' do
      out = run_command(session_manager([], 'fallback-model'))

      expect(out).to include('No model profiles configured.')
      expect(out).to include('Current model: fallback-model (@ http://cfg:11434/v1)')
    end

    it 'prints no listing header' do
      expect(run_command(session_manager([], 'm'))).not_to include('Configured models')
    end
  end

  it 'declares its HELP entry' do
    help = described_class::HELP
    expect(help.usage).to eq('models')
    expect(help.group).to eq(:model)
    expect(help.see_also).to eq(%w[model param])
  end
end
