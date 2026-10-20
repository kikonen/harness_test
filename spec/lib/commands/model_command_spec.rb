# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'file_list'
require 'tmpdir'
require 'commands/model_command'

# /model talks only to harness.session_manager (active model, target display,
# switch_model, param_overrides), so a thin double exposing those is enough -
# same approach as param_command_spec.
RSpec.describe Commands::ModelCommand do
  def session_manager(profiles, active, target: '/v1/chat/completions')
    sm = Object.new
    sm.define_singleton_method(:model_profiles) { profiles }
    sm.define_singleton_method(:active_model_name) { active }
    sm.define_singleton_method(:target_display) { target }
    sm.define_singleton_method(:switch_model) { |name| profiles.find { |p| p[:name] == name } }
    po = Object.new
    po.define_singleton_method(:list_display) { ['  temperature: 0.7  (default)'] }
    sm.define_singleton_method(:param_overrides) { po }
    sm
  end

  def harness(manager)
    h = Object.new
    h.define_singleton_method(:session_manager) { manager }
    h
  end

  def run_command(args = '', manager: nil, options: { base_url: 'http://srv:11434/v1' })
    manager ||= session_manager([{ name: 'qwen', model: 'qwen3:8b' }], 'qwen')
    stdout = StringIO.new
    described_class.new(harness: harness(manager), file_list: nil, options: options,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  describe 'with no argument (show the active model)' do
    it 'names the model, its endpoint path and the base url' do
      out = run_command

      expect(out).to include('Current model: qwen')
      expect(out).to include('/v1/chat/completions')
      expect(out).to include('http://srv:11434/v1')
    end

    # issue #219: the parameter listing is shared with /param, so /model prints it.
    it 'prints every parameter through the shared ParamOverrides listing' do
      expect(run_command).to include('temperature: 0.7')
    end

    it 'closes with the pointers to /models, /model <name> and /param' do
      out = run_command
      expect(out).to include('List models with /models')
      expect(out).to include('adjust parameters with /param')
    end
  end

  describe 'with a name (switch the model)' do
    it 'reports the profile it switched to' do
      sm = session_manager([{ name: 'qwen', model: 'qwen3:8b' },
                            { name: 'big', model: 'llama3:70b', url: 'http://other:11434/v1' }],
                           'qwen')
      out = run_command('big', manager: sm)

      expect(out).to include('Switched to model: big')
      expect(out).to include('llama3:70b')
      expect(out).to include('http://other:11434/v1') # the profile's own url wins
      expect(out).to include('/v1/chat/completions')
    end

    # A profile may key its label under :model only, and its url under the
    # global default - both fallbacks are what make the line complete.
    it 'falls back to :model for the name and to the global base url for the endpoint' do
      mgr = session_manager([{ name: 'bare', model: 'bare-model' }], 'qwen')
      out = run_command('bare', manager: mgr)

      expect(out).to include('Switched to model: bare (bare-model @ http://srv:11434/v1)')
    end

    it 'prints the parameter listing after a switch too' do
      sm = session_manager([{ name: 'qwen', model: 'qwen3:8b' },
                            { name: 'big', model: 'llama3:70b' }], 'qwen')
      expect(run_command('big', manager: sm)).to include('temperature: 0.7')
    end

    # An unknown name finds no profile: switch_model returns nil and the command
    # must fail loudly rather than print an empty line.
    it 'raises when the name matches no profile' do
      expect { run_command('ghost', manager: session_manager([{ name: 'qwen' }], 'qwen')) }
        .to raise_error(NoMethodError)
    end
  end

  it 'declares both accepted forms in its HELP' do
    help = described_class::HELP
    expect(help.usage).to eq('model [name]')
    expect(help.forms).to eq(['model', 'model <name>'])
    expect(help.group).to eq(:model)
  end
end
