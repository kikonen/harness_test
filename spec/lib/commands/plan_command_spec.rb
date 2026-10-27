# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/plan_command'

# issue #359: /plan flips the planning posture. Like /stream it changes
# USER-side harness state only, acks with the new label, and states what the
# mode does. Advisory by the owner's decision: the command gates nothing.
RSpec.describe Commands::PlanCommand do
  # Stand-in for Harness exposing the posture surface the command uses.
  def build_harness(plan: false)
    Class.new do
      attr_accessor :plan

      def initialize(plan)
        @plan = plan
      end

      def plan?
        @plan
      end

      def toggle_plan
        @plan = !@plan
        plan_mode_label
      end

      def plan_mode_label
        @plan ? 'PLAN' : nil
      end
    end.new(plan)
  end

  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command(harness = build_harness)
    described_class.new(harness: harness, file_list: nil, options: nil, ui: ui)
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
    harness = build_harness
    command(harness).handle('')

    expect(harness.plan?).to be(true)
    expect(io.string).to include('[PLAN]')
    expect(io.string).to include('Advisory mode: no tool is refused')
  end

  it 'toggles back off with a second /plan' do
    harness = build_harness(plan: true)
    command(harness).handle('')

    expect(harness.plan?).to be(false)
    # Off is the default, so the ack names the off state, not a badge.
    expect(io.string).to include('[PLANNING OFF]')
  end

  it 'sets the posture explicitly with on and off' do
    harness = build_harness
    command(harness).handle('on')
    expect(harness.plan?).to be(true)

    command(harness).handle('off')
    expect(harness.plan?).to be(false)
  end

  it 'reports the current posture with status without changing it' do
    harness = build_harness(plan: true)
    command(harness).handle('status')

    expect(harness.plan?).to be(true)
    expect(io.string).to include('[PLAN]')
  end

  it 'states the advisory expectation when the mode is on' do
    command(build_harness(plan: true)).handle('status')

    expect(io.string).to include('draft and iterate a plan with plan.add')
    expect(io.string).to include('no tool is refused')
  end

  it 'shows usage for an argument that is not a posture keyword' do
    command(build_harness).handle('quiet-harbor')

    expect(io.string).to include('usage: /plan')
  end
end
