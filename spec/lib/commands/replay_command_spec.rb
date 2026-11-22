# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'job_registry'
require 'system_settings'
require 'commands/replay_command'

# /replay (issue #458 / #286) reads the run RECORD through the registry and redraws
# it the way the startup replay does: one UI::Renderer#line per stored entry
# between two block rules. The spec records through the registry and asserts the
# lines that redraw produces - the record's own roles, not a flattened table.
RSpec.describe Commands::ReplayCommand do
  def run(args, registry, settings: nil)
    io = StringIO.new
    described_class.new(registry:, file_list: nil, settings:,
                        ui: UI::Console.new(stdout: io)).handle(args)
    io.string
  end

  def recorded_registry
    JobRegistry.new(max_saved: 30).tap do |registry|
      main = registry.add_job(kind: :main)
      registry.record_user_prompt('do the thing')
      registry.record_report_output(type: :response, origin: 'session_manager',
                                    content: 'working')
      registry.add_job(kind: :sub_agent, requested_by: main)
    end
  end

  # The startup replay's shape: blank, rule, header, entries, rule.
  def rule_lines(out)
    out.lines.map(&:chomp).count { |l| l == '-' * UI::Renderer::RULE_WIDTH }
  end

  describe 'the foreground job by default' do
    it 'redraws the recorded tail through the renderer between two rules' do
      out = run('', recorded_registry)

      expect(rule_lines(out)).to eq(2)
      expect(out).to include('Replay [job 0 main] FOREGROUND (main, pending): 2 of 2 recorded lines')
      # A :user record keeps its role label, exactly as the resume redraw shows it
      # (the renderer pads the label, so the match stops before the gap).
      expect(out).to include('user:')
      expect(out).to include('do the thing')
      expect(out).to include('working')
    end

    it 'shows the newest n lines and says how many it hid' do
      registry = recorded_registry
      5.times { |i| registry.record_report_output(type: :text, origin: 'c', content: "l#{i}") }

      out = run('3', registry)

      expect(out).to include('3 of 7 recorded lines')
      expect(out).not_to include('l0')
      expect(out).to include('l4')
    end

    it 'caps at the saved window the record holds' do
      registry = JobRegistry.new(max_saved: 4)
      registry.add_job(kind: :main)
      6.times { |i| registry.record_report_output(type: :text, origin: 'c', content: "l#{i}") }

      out = run('20', registry)

      expect(out).to include('4 of 4 recorded lines')
    end

    it 'reports an empty record instead of an empty block' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)

      expect(run('', registry)).to include('nothing recorded')
    end

    it 'says nothing to replay when there is no registry' do
      io = StringIO.new
      described_class.new(file_list: nil,
                          ui: UI::Console.new(stdout: io)).handle('')

      expect(io.string).to include('No registry')
    end

    it 'honours limit 0 as print nothing' do
      expect(run('0', recorded_registry)).to include('limit 0 prints nothing')
    end
  end

  describe 'one job or every job (issue #548)' do
    it 'reads a job that is not the foreground one' do
      registry = recorded_registry
      registry.foreground = registry.job(1).id
      # Recorded after the switch, so this line belongs to job 1's buffer.
      registry.record_user_prompt('background line')

      out = run('job 0', registry)

      expect(out).to include('Replay [job 0 main] (main, pending)')
      expect(out).to include("user:  do the thing")
      expect(out).not_to include('background line')
    end

    it 'labels each job when all is asked for' do
      registry = recorded_registry
      registry.record_user_prompt('sub line')
      out      = run('all', registry)

      expect(out).to include('Replay [job 0 main] FOREGROUND (main, pending)')
      expect(out).to include('Replay [job 1 sub_agent] (sub_agent, pending)')
      expect(out).to include("user:  sub line")
    end

    it 'reports an id the registry does not retain' do
      registry = JobRegistry.new
      registry.add_job(kind: :main)

      expect(run('job 7', registry)).to include('job 7 is not retained')
    end
  end

  # A structured :list report is stored AS a structure (issue #146), so replaying
  # it redraws the report rather than a string of it.
  it 'redraws a recorded list report as a report' do
    registry = JobRegistry.new
    registry.add_job(kind: :main)
    registry.record_report_output(
      type: :list,
      origin: 'jobs',
      content: { title: 'Jobs (foreground marked *)', kind: :table,
                 columns: %i[job kind], items: [{ job: '#0', kind: 'main' }] })

    out = run('', registry)

    expect(out).to include('Jobs (foreground marked *)')
    expect(out).to include('| #0')
  end
end
