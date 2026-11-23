# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'file_list'
require 'spill_reader'
require 'result_spill'
require 'session_locator'
require 'output_budget'

RSpec.describe SpillReader do
  def workdir
    @workdir ||= Dir.mktmpdir('spill-reader-spec')
  end

  after { FileUtils.remove_entry(@workdir) if @workdir && File.directory?(@workdir) }

  let(:locator) { SessionLocator.new(workdir, session_id: 'sess-1') }
  let(:file_list) { FileList.new([], workdir: workdir) }
  let(:limit) { 400 }
  let(:reader) do
    described_class.new(
      file_list: file_list,
      result_spill: -> { spill },
      output_result_bytes: limit)
  end
  let(:spill) { ResultSpill.new(locator) }

  def spill_path(tool, seq)
    File.join('.harness', 'sessions', 'sess-1', 'jobs', '0', 'results', "#{tool}-#{seq}.txt")
  end

  it 'returns nil for a path that is not this job spill dir' do
    expect(reader.read_spilled_result('lib/harness.rb')).to be_nil
    expect(reader.read_spilled_result('.harness/sessions/other/jobs/0/results/x-1.txt')).to be_nil
  end

  it 'reads a spill through the byte budget and marks it already capped' do
    spill.write('run.command', 1, 'x' * 2000)

    result = reader.read_spilled_result(spill_path('run.command', 1))

    expect(result).to start_with(ResultSpill::ALREADY_CAPPED_MARK)
    expect(result.bytesize).to be <= limit + 200
    expect(result).to include('bytes omitted')
  end

  # issue #595: a pruned spill must not fall through to the file tools and read as
  # "access denied" - the honest answer is that the window dropped it.
  it 'answers a pruned spill path with what happened, not a denial' do
    tiny  = ResultSpill.new(locator, keep: 1)
    tiny.write('run.command', 1, 'old output')
    tiny.write('run.command', 2, 'new output')
    tiny.prune

    result = reader.read_spilled_result(spill_path('run.command', 1))

    expect(result).to start_with(ResultSpill::ALREADY_CAPPED_MARK)
    expect(result).to include('no longer kept')
    expect(result).to include('Re-run the command')
    expect(result).not_to include('denied')
  end

  it 'reports a read failure instead of raising' do
    spill.write('run.command', 1, 'text')
    path = spill_path('run.command', 1)
    allow(File).to receive(:size).and_raise(Errno::EACCES, 'read-only file system')

    expect(reader.read_spilled_result(path)).to include('error: cannot read')
  end
end
