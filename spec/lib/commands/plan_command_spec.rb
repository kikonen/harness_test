# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/plan_command'
require 'system_settings'

# issue #359: /plan flips the planning posture. Like /stream it changes
# USER-side harness state only, acks with the new label, and states what the
# mode does. Advisory by the owner's decision: the command gates nothing.
RSpec.describe Commands::PlanCommand do
  # The command talks to SystemSettings directly (#286): use the real one.
  def build_settings(plan: false)
    SystemSettings.new(plan: plan)
  end

  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command(settings = build_settings)
    described_class.new(settings: settings, file_list: nil, options: nil, ui: ui)
  end

  describe 'the help entry (issue #323 contract)' do
    it 'declares a HELP entry whose usage starts with its registered name' do
      help = described_class.help

      expect(help.usage).to start_with('plan')
      expect(help.summary).not_to be_empty
      expect(CommandHelp::GROUPS).to have_key(help.group)
    end
  end

  it 'toggles the posture on a bare /plan and acks the new label' do
    settings = build_settings
    command(settings).handle('')

    expect(settings.plan?).to be(true)
    expect(io.string).to include('[PLAN]')
    expect(io.string).to include('Advisory mode: no tool is refused')
  end

  it 'toggles back off with a second /plan' do
    settings = build_settings(plan: true)
    command(settings).handle('')

    expect(settings.plan?).to be(false)
    # Off is the default, so the ack names the off state, not a badge.
    expect(io.string).to include('[PLANNING OFF]')
  end

  it 'sets the posture explicitly with on and off' do
    settings = build_settings
    command(settings).handle('on')
    expect(settings.plan?).to be(true)

    command(settings).handle('off')
    expect(settings.plan?).to be(false)
  end

  it 'reports the current posture with status without changing it' do
    settings = build_settings(plan: true)
    command(settings).handle('status')

    expect(settings.plan?).to be(true)
    expect(io.string).to include('[PLAN]')
  end

  it 'states the advisory expectation when the mode is on' do
    command(build_settings(plan: true)).handle('status')

    expect(io.string).to include('draft and iterate a plan with plan.add')
    expect(io.string).to include('no tool is refused')
  end

  it 'shows usage for an argument that is not a posture keyword' do
    command(build_settings).handle('quiet-harbor')

    expect(io.string).to include('usage: /plan')
  end
end
