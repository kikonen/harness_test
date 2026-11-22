# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'file_list'
require 'job_registry'
require 'tmpdir'
require 'commands/model_command'

# /model talks only to harness.session_manager (active model, target display,
# switch_profile, param_overrides), so a thin double exposing those is enough -
# same approach as param_command_spec.
RSpec.describe Commands::ModelCommand do
  def session_manager(profiles, active, target: '/v1/chat/completions', vision: false)
    sm = Object.new
    sm.define_singleton_method(:model_profiles) { profiles }
    sm.define_singleton_method(:active_profile_name) { active }
    sm.define_singleton_method(:target_display) { target }
    # issue #449: image support is a session_manager fact (the active profile's
    # 'vision:'), so /model reads it from there.
    sm.define_singleton_method(:vision?) { vision }
    sm.define_singleton_method(:switch_profile) do |id|
      profile = profiles.find { |p| p[:id] == id }
      raise HarnessError, "no such profile '#{id}'" if profile.nil?

      profile
    end
    po = Object.new
    po.define_singleton_method(:list_items) do
      [{ key: 'temperature', value: '0.7', annotation: '' }]
    end
    sm.define_singleton_method(:param_overrides) { po }
    sm
  end

  def harness(manager)
    h = Object.new
    h.define_singleton_method(:session_manager) { manager }
    # /model reads the live endpoint from THIS harness' ModelConfig (#286),
    # not from settings - so the double exposes a model_config answering base_url.
    model_config = Object.new
    model_config.define_singleton_method(:base_url) { 'http://srv:11434/v1' }
    h.define_singleton_method(:model_config) { model_config }
    h
  end

  def run_command(args = '', manager: nil, vision: false)
    manager ||= session_manager([{ name: 'qwen', id: 'qwen' }], 'qwen', vision: vision)
    stdout = StringIO.new
    # #286: the command reaches the Harness through the foreground job's harness,
    # so the spec builds a registry whose main job carries the double.
    registry = JobRegistry.new
    registry.add_job(kind: :main, harness: harness(manager))
    described_class.new(registry:, file_list: nil,
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
    it 'prints every parameter through the shared ParamOverrides table' do
      out = run_command
      row = out.lines.map(&:chomp).find { |l| l.include?('temperature') }

      # A :table cell renders value in its own column, so key and value are
      # separate cells (no fused "temperature: 0.7").
      expect(row).to include('temperature')
      expect(row).to include('0.7')
    end

    it 'closes with the pointers to /models, /model <id> and /param' do
      out = run_command
      # The pointer line is a :note paragraph the renderer re-wraps to a fixed
      # width; match on whitespace-collapsed text so a wrap point inside a
      # phrase (e.g. "/param" landing on the next line) stays out of the assert.
      squashed = out.gsub(/\s+/, " ")
      expect(squashed).to include('List models with /models')
      expect(squashed).to include('adjust parameters with /param')
    end

    # issue #449: image support is per-profile and not a generation parameter,
    # so the /param listing does not cover it - /model names it separately.
    it 'names whether this model can be sent images' do
      expect(run_command).to include('files only (no vision declared)')
    end

    it 'says the active profile inlines images when it declares vision' do
      expect(run_command(vision: true)).to include('inlined to the model')
    end
  end

  describe 'with a name (switch the model)' do
    it 'reports the profile it switched to' do
      sm = session_manager([spec_profile('qwen'),
                            spec_profile('big', url: 'http://other:11434/v1')],
                           'qwen')
      out = run_command('big', manager: sm)

      expect(out).to include('Switched to model: big')
      expect(out).to include('http://other:11434/v1') # the profile's own url wins
      expect(out).to include('/v1/chat/completions')
    end

    # A switch reports the profile's OWN endpoint - a configured profile always
    # carries a url, so there is no fallback to the run's base url to display.
    it 'reports the profile endpoint it switched to' do
      mgr = session_manager([spec_profile('bare', url: 'http://bare:11434/v1')], 'qwen')
      out = run_command('bare', manager: mgr)

      expect(out).to include('Switched to model: bare (bare @ http://bare:11434/v1)')
    end

    it 'prints the parameter table after a switch too' do
      sm = session_manager([spec_profile('qwen'), spec_profile('big')], 'qwen')
      row = run_command('big', manager: sm).lines.map(&:chomp).find { |l| l.include?('temperature') }

      expect(row).to include('temperature')
      expect(row).to include('0.7')
    end

    # An unknown id names no profile: switch_profile raises rather than let the
    # command print an empty line.
    it 'raises when the id matches no profile' do
      expect { run_command('ghost', manager: session_manager([{ name: 'qwen', id: 'qwen' }], 'qwen')) }
        .to raise_error(HarnessError, /no such profile/)
    end
  end

  it 'declares both accepted forms in its HELP' do
    help = described_class::HELP
    expect(help.usage).to eq('model [id]')
    expect(help.forms).to eq(['model', 'model <id>'])
    expect(help.group).to eq(:model)
  end
end
