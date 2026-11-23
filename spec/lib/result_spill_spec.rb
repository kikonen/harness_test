# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'result_spill'
require 'session_locator'

# The overflow target of issue #551: the chain keeps a preview, the full text
# goes beside the job that produced it.
RSpec.describe ResultSpill do
  def workdir
    @workdir ||= Dir.mktmpdir('spill-spec')
  end

  after { FileUtils.remove_entry(@workdir) if @workdir && File.directory?(@workdir) }

  def spill(session_id, job_id: 0)
    described_class.new(SessionLocator.new(workdir, session_id:), job_id:)
  end

  it 'writes the full text under the job dir and reports a workdir-relative path' do
    path = spill('sess-1').write('run.command', 2, 'full 10 MB output')
    job  = SessionLocator.new(workdir, session_id: 'sess-1').job_dir(0)

    expect(path).to eq(File.join('.harness', 'sessions', 'sess-1', 'jobs', '0',
                                 'results', 'run.command-2.txt'))
    expect(File.read(File.join(job, 'results', 'run.command-2.txt'))).to eq('full 10 MB output')
  end

  it 'files each job result in that job OWN dir' do
    spill('sess-1', job_id: 3).write('run.command', 1, 'child output')
    job = SessionLocator.new(workdir, session_id: 'sess-1').job_dir(3)

    expect(File.read(File.join(job, 'results', 'run.command-1.txt'))).to eq('child output')
  end

  it 'reduces a tool name to one safe segment (no path escape through a name)' do
    path = spill('sess-1').write('../../evil', 1, 'x')

    expect(path).to include('.._evil-1.txt')
    expect(path.split('/')).not_to include('..')
  end

  it 'never clobbers an earlier spill of the same tool and sequence' do
    spill('sess-1').write('run.command', 1, 'first')
    path = described_class.new(SessionLocator.new(workdir, session_id: 'sess-1'))
               .write('run.command', 2, 'second')

    expect(File.read(File.join(workdir, path))).to eq('second')
  end
  describe "#covers? (the spill path a read must answer itself)" do
    it "matches a file in this job results dir" do
      s = spill("sess-1")

      expect(s.covers?(".harness/sessions/sess-1/jobs/0/results/run.command-1.txt")).to be true
    end

    it "does not match another job dir or another session" do
      s = spill("sess-1", job_id: 2)

      expect(s.covers?(".harness/sessions/sess-1/jobs/0/results/run.command-1.txt")).to be false
      expect(s.covers?(".harness/sessions/other/jobs/2/results/run.command-1.txt")).to be false
      expect(s.covers?(".harness/sessions/sess-1/jobs/2/harness.log")).to be false
    end

    it "refuses a name carrying .. instead of resolving it" do
      s = spill("sess-1")

      expect(s.covers?(".harness/sessions/sess-1/jobs/0/results/../../harness.log")).to be false
      expect(s.covers?("")).to be false
    end
  end

  # issue #595: the dir grew without bound because nothing ever removed a spill.
  describe "#prune (the window that bounds the dir)" do
    def names(session_id, job_id: 0)
      dir = SessionLocator.new(workdir, session_id:).job_dir(job_id)
      Dir.glob(File.join(dir, 'results', '*.txt')).map { |p| File.basename(p) }.sort
    end

    it 'keeps the newest keep entries by sequence number, not by mtime' do
      s = described_class.new(SessionLocator.new(workdir, session_id: 'sess-1'), keep: 3)
      %w[a b c d e f].each_with_index { |t, i| s.write(t, i + 1, "out #{i}") }

      removed = s.prune

      expect(removed.size).to eq(3)
      expect(names('sess-1')).to eq(%w[d-4.txt e-5.txt f-6.txt])
    end

    it 'removes nothing while the dir is inside the window' do
      s = described_class.new(SessionLocator.new(workdir, session_id: 'sess-1'), keep: 10)
      3.times { |i| s.write('run.command', i + 1, 'x') }

      expect(s.prune).to eq([])
      expect(names('sess-1').size).to eq(3)
    end

    it 'prunes only THIS job dir' do
      other = described_class.new(SessionLocator.new(workdir, session_id: 'sess-1'), job_id: 3, keep: 10)
      own   = described_class.new(SessionLocator.new(workdir, session_id: 'sess-1'), job_id: 0, keep: 1)
      3.times { |i| other.write('run.command', i + 1, 'x') }
      3.times { |i| own.write('run.command', i + 1, 'x') }

      own.prune

      expect(names('sess-1', job_id: 0).size).to eq(1)
      expect(names('sess-1', job_id: 3).size).to eq(3)
    end

    it 'is a no-op when the window is disabled (0 or negative)' do
      s = described_class.new(SessionLocator.new(workdir, session_id: 'sess-1'), keep: 0)
      3.times { |i| s.write('run.command', i + 1, 'x') }

      expect(s.prune).to eq([])
      expect(names('sess-1').size).to eq(3)
    end

    it 'is a no-op when the dir does not exist yet' do
      expect(spill('never-used').prune).to eq([])
    end
  end

  describe "#pruned? (a path the window already removed)" do
    it 'is true for a spill path inside this job dir that is gone' do
      s = described_class.new(SessionLocator.new(workdir, session_id: 'sess-1'), keep: 1)
      s.write('run.command', 1, 'old')
      s.write('run.command', 2, 'new')
      s.prune

      expect(s.pruned?('.harness/sessions/sess-1/jobs/0/results/run.command-1.txt')).to be true
      expect(s.pruned?('.harness/sessions/sess-1/jobs/0/results/run.command-2.txt')).to be false
    end

    it 'is false for a path outside this job dir' do
      expect(spill('sess-1').pruned?('.harness/sessions/sess-1/jobs/9/results/x-1.txt')).to be false
    end
  end
end
