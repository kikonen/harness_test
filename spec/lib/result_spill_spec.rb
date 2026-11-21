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
    described_class.new(SessionLocator.new(workdir), session_id, job_id:)
  end

  it 'writes the full text under the job dir and reports a workdir-relative path' do
    path = spill('sess-1').write('run.command', 2, 'full 10 MB output')
    job  = SessionLocator.new(workdir).job_dir_path('sess-1', 0)

    expect(path).to eq(File.join('.harness', 'sessions', 'sess-1', 'jobs', '0',
                                 'results', 'run.command-2.txt'))
    expect(File.read(File.join(job, 'results', 'run.command-2.txt'))).to eq('full 10 MB output')
  end

  it 'files each job result in that job OWN dir' do
    spill('sess-1', job_id: 3).write('run.command', 1, 'child output')
    job = SessionLocator.new(workdir).job_dir_path('sess-1', 3)

    expect(File.read(File.join(job, 'results', 'run.command-1.txt'))).to eq('child output')
  end

  it 'refuses to write when the run has no session id yet' do
    expect(spill(nil).write('run.command', 1, 'x')).to be_nil
    expect(spill('').write('run.command', 1, 'x')).to be_nil
  end

  it 'reduces a tool name to one safe segment (no path escape through a name)' do
    path = spill('sess-1').write('../../evil', 1, 'x')

    expect(path).to include('.._evil-1.txt')
    expect(path.split('/')).not_to include('..')
  end

  it 'never clobbers an earlier spill of the same tool and sequence' do
    spill('sess-1').write('run.command', 1, 'first')
    path = described_class.new(SessionLocator.new(workdir), 'sess-1')
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
end
