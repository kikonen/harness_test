# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'param_overrides'
require 'commands/param_command'

# issue #219: /param shows and adjusts the LLM parameters for this session.
# The command only talks to the shared ParamOverrides object, so a thin
# harness double exposing a real one is enough.
RSpec.describe Commands::ParamCommand do
  let(:opts) { { reasoning_effort: 'medium', num_ctx: 65_536 } }
  let(:profile) { { reasoning_effort: 'medium', num_ctx: 65_536 } }
  let(:param) { ParamOverrides.new(opts, profile: -> { profile }) }

  # Minimal harness double: the command only reads .session_manager.
  let(:harness) do
    po = param # captured: the singleton-method blocks run on a bare Object
    sm = Object.new
    sm.define_singleton_method(:param_overrides) { po }
    h  = Object.new
    h.define_singleton_method(:session_manager) { sm }
    h
  end

  def run_command(args = '')
    io = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: io)).handle(args)
    io.string
  end

  it 'lists every parameter with its effective value and source' do
    out = run_command

    expect(out).to include('reasoning_effort')
    expect(out).to include('num_ctx')
    expect(out).to include('medium')
    expect(out).to include('65536')
    expect(out).to include('default')
  end

  it 'marks session overrides in the list' do
    param.set('reasoning_effort', 'low')
    out = run_command

    expect(out).to include('low')
    expect(out).to include('override')
  end

  it 'shows a single parameter' do
    out = run_command('num_ctx')

    expect(out).to include('num_ctx: 65536')
  end

  it 'sets a session-level override and confirms it' do
    out = run_command('reasoning_effort low')

    expect(out).to include('reasoning_effort: low')
    expect(out).to include('session override')
    expect(opts[:reasoning_effort]).to eq('low')
  end

  it 'resets a parameter back to the profile value with default' do
    param.set('reasoning_effort', 'low')
    out = run_command('reasoning_effort default')

    expect(out).to include('reset')
    expect(opts[:reasoning_effort]).to eq('medium')
  end

  it 'reports an unknown parameter' do
    expect { run_command('bogus 1') }
      .to raise_error(HarnessError, /unknown parameter 'bogus'/)
  end

  it 'prints usage when given too many arguments' do
    out = run_command('a b c')

    expect(out).to include('usage:')
  end
end
