# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'harness'
require 'file_list'
require 'system_settings'

# Issue #551: the size gate that keeps a tool result from becoming a message so
# large the backend refuses the WHOLE next request (and with it the compaction
# that would have repaired the run). The gate runs before the result becomes a
# message, so it is tested at that seam.
RSpec.describe Harness, 'tool-result byte budget (issue #551)' do
  let(:workdir) { Dir.mktmpdir('budget-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }
  before { allow_any_instance_of(SandboxGemfile).to receive(:lock_seeded?).and_return(true) }

  def build(options = {})
    opts = { system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE,
             num_ctx: 65_536 }.merge(options)
    session_id = opts.delete(:session_id)
    described_class.new(FileList.new([], workdir: workdir),
                        settings: SystemSettings.from_options(opts),
                        session_id:)
  end

  def huge(bytes: 200_000)
    'A' * bytes
  end

  def spill_path(session, tool: 'run.command', seq: 1)
    ".harness/sessions/#{session}/jobs/0/results/#{tool}-#{seq}.txt"
  end

  def log_of(session)
    File.read(File.join(workdir, '.harness', 'sessions', session, 'harness.log'))
  end

  it 'leaves an ordinary result untouched' do
    h = build

    expect(h.budget_tool_result('run.command', 'exit code: 0\n--- output ---\nhi')).to eq(
      'exit code: 0\n--- output ---\nhi')
  end

  it 'caps a huge result to the byte budget' do
    h = build(output_result_bytes: 10_000)
    out = h.budget_tool_result('run.command', huge)

    expect(out.bytesize).to be < huge.bytesize
    expect(out).to include('bytes omitted')
  end

  it 'names the file the full output was saved to' do
    h   = build(output_result_bytes: 10_000, session_id: 'sess-1')
    out = h.budget_tool_result('run.command', huge)

    expect(out).to include(spill_path('sess-1'))
    expect(File.read(File.join(workdir, spill_path('sess-1')))).to eq(huge)
  end

  it 'numbers successive spills so they do not overwrite each other' do
    h = build(output_result_bytes: 10_000, session_id: 'sess-2')
    first  = h.budget_tool_result('run.command', huge)
    second = h.budget_tool_result('git.show', huge)

    expect(first).to include('run.command-1.txt')
    expect(second).to include('git.show-2.txt')
  end

  it 'spills into the job that produced the result' do
    h = build(output_result_bytes: 10_000, session_id: 'sess-3')
    h.session_manager.job_id = 4
    out = h.budget_tool_result('run.command', huge)

    expect(out).to include('.harness/sessions/sess-3/jobs/4/results/run.command-1.txt')
  end

  it 'uses the built-in default when the config says nothing' do
    h = build

    expect(h.output_result_bytes).to eq(OutputBudget::DEFAULT_RESULT_BYTES)
  end

  # Image bytes are not text: the cap belongs to ImageDelivery's own budget
  # (issue #449), and flattening a ToolResult here would drop the images.
  it 'hands a ToolResult through untouched' do
    h      = build(output_result_bytes: 1_000)
    result = ToolResult.new(text: 'shot', images: [
      ToolResult::Image.new(server: 'b', tool: 't', mime_type: 'image/png', bytes: ('x' * 5000).b)
    ])

    expect(h.budget_tool_result('blender.shot', result)).to be(result)
  end

  it 'reports the cap in harness.log so an oversized command is recoverable' do
    h   = build(output_result_bytes: 10_000, session_id: 'sess-4')
    out = h.budget_tool_result('run.command', huge)
    log = File.read(File.join(workdir, '.harness', 'sessions', 'sess-4', 'harness.log'))

    expect(out).to include('omitted')
    expect(log).to include('tool run.command result 200000 B capped to')
  end

  # The overflow is text in the chain, so the cap must be valid UTF-8 for the
  # session save that follows it (the #257 family).
  it 'keeps a capped multi-byte result saveable' do
    h   = build(output_result_bytes: 10_000)
    out = h.budget_tool_result('run.command', "\u4e2d" * 60_000)

    expect(out.valid_encoding?).to be true
    expect { JSON.generate({ 'result' => out }) }.not_to raise_error
  end

  # A session dir is harness state, so the model cannot open a spill with the file
  # tools; the tool that spilled answers the read - and caps it, because reading
  # the overflow back whole would be the same overflow one step later.
  describe 'reading a spill back' do
    it 'answers a read of its own spill file, capped' do
      h = build(output_result_bytes: 10_000, session_id: 'sess-5')
      h.budget_tool_result('run.command', huge)

      out = h.read_spilled_result(spill_path('sess-5'))

      expect(out.bytesize).to be < huge.bytesize
      expect(out).to include('bytes omitted from the middle of 200000')
    end

    it 'answers nothing for a path that is not this job spill' do
      h = build(output_result_bytes: 10_000, session_id: 'sess-6')
      h.budget_tool_result('run.command', huge)

      expect(h.read_spilled_result('lib/harness.rb')).to be_nil
      expect(h.read_spilled_result(spill_path('other'))).to be_nil
    end

    it 'accepts the absolute form of the same path' do
      h = build(output_result_bytes: 10_000, session_id: 'sess-7')
      h.budget_tool_result('run.command', huge)

      expect(h.read_spilled_result(File.join(workdir, spill_path('sess-7'))))
        .to include('omitted')
    end
    # A spill file is slightly BIGGER than the byte budget (the notice is added
    # on the way out), so a spill read that came back over the limit was fitted
    # again: the read spilled the spill and harness.log reported a cap the model
    # never received.
    it 'does not re-spill a spill read that is already capped' do
      h = build(output_result_bytes: 10_000, session_id: 'sess-9')
      h.budget_tool_result('run.command', huge(bytes: 10_060))

      out = h.budget_tool_result('file.read',
                                 h.read_spilled_result(spill_path('sess-9')))

      expect(Dir.glob(File.join(workdir, '.harness', 'sessions', 'sess-9',
                                'jobs', '0', 'results', '*'))
             .map { |f| File.basename(f) }).to eq(['run.command-1.txt'])
      expect(log_of('sess-9')).not_to include('tool file.read result')
      expect(out).not_to include('spilled tool output')
    end

    it 'still caps a spill read of its own oversized spill file' do
      h = build(output_result_bytes: 10_000, session_id: 'sess-10')
      FileUtils.mkdir_p(File.dirname(File.join(workdir, spill_path('sess-10'))))
      File.write(File.join(workdir, spill_path('sess-10')), huge(bytes: 500_000))

      out = h.budget_tool_result('file.read',
                                 h.read_spilled_result(spill_path('sess-10')))

      expect(out.bytesize).to be < 20_000
      expect(out).to include('bytes omitted from the middle of 500000')
    end
  end

  # The model's own recovery route: file.read on the spill path must reach the
  # owner BEFORE the grant dialog, since no grant can ever open a session dir.
  it 'lets file.read reach a spill through its owner' do
    h      = build(output_result_bytes: 10_000, session_id: 'sess-8')
    tool   = Tools::FileReadTool.new(FileList.new([], workdir: workdir), nil,
                                     spill_reader: h)
    h.budget_tool_result('run.command', huge)

    out = tool.execute('path' => spill_path('sess-8'))

    expect(out).not_to start_with('error: access denied')
    expect(out).to include('bytes omitted from the middle')
  end

end
