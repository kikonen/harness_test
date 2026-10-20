# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'file_list'
require 'git_runner'

# GitRunner is the shared base of the git.* tools: abstract execute, protected
# helpers. The probe stands in for a concrete tool so the helpers are reachable.
class ProbeGitRunner < GitRunner
  def initialize(file_list)
    @file_list = file_list
    super(name: 'probe.git', description: 'probe git runner', parameters: {})
  end
end

# The git.* tools run REAL git, so the base's env setup is asserted against a real
# repository rather than a stub (same approach as git_apply_tool_spec).
# maintenance.auto / gc.auto are switched off through git's own config env so no
# detached `git maintenance` child writes into the tmp repo while Dir.mktmpdir is
# walking the same tree to delete it.
RUNNER_GIT_ENV = {
  'GIT_AUTHOR_NAME'     => 'test',
  'GIT_AUTHOR_EMAIL'    => 'test@example.com',
  'GIT_COMMITTER_NAME'  => 'test',
  'GIT_COMMITTER_EMAIL' => 'test@example.com',
  'GIT_CONFIG_COUNT'    => '2',
  'GIT_CONFIG_KEY_0'    => 'maintenance.auto',
  'GIT_CONFIG_VALUE_0'  => 'false',
  'GIT_CONFIG_KEY_1'    => 'gc.auto',
  'GIT_CONFIG_VALUE_1'  => '0'
}.freeze

RSpec.describe GitRunner do
  def runner_for(dir)
    ProbeGitRunner.new(FileList.new([], workdir: dir))
  end

  def setup_repo(dir, file: 'hello.txt', content: "line1\nline2\nline3\n")
    File.write(File.join(dir, file), content)
    system(RUNNER_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
    system(RUNNER_GIT_ENV, 'git', 'add', file, chdir: dir, exception: true)
    system(RUNNER_GIT_ENV, 'git', 'commit', '-q', '-m', 'init', chdir: dir, exception: true)
  end

  describe '#execute' do
    it 'is abstract on the base class' do
      Dir.mktmpdir do |dir|
        expect { runner_for(dir).execute({}) }
          .to raise_error(NotImplementedError, /ProbeGitRunner#execute not implemented/)
      end
    end
  end

  describe '#run_git' do
    it 'runs in the harness working directory and returns status/stdout/stderr' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        result = runner_for(dir).send(:run_git, 'git', 'status', '--short')

        expect(result[:status]).to eq(0)
        expect(result[:stdout]).to eq('')
        expect(result[:stderr]).to eq('')
      end
    end

    it 'reports a non-zero exit status instead of raising' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        result = runner_for(dir).send(:run_git, 'git', 'diff', 'nosuchrev')

        expect(result[:status]).to eq(128)
        expect(result[:stderr]).to include('unknown revision')
      end
    end

    # The env block is why the tools work headless: without GIT_PAGER a long log
    # waits on a TTY, and without color.ui=false the captured text carries SGR
    # bytes the model would then read as part of the diff.
    it 'captures plain text with no color and no pager interaction' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = runner_for(dir).send(:run_git, 'git', 'log', '--stat')[:stdout]

        expect(out).to include('hello.txt')
        expect(out).not_to include("\e[")
      end
    end

    it 'normalizes output to valid UTF-8 (issue #257: a diff can carry binary)' do
      Dir.mktmpdir do |dir|
        setup_repo(dir, file: 'bin.dat', content: "ok\n\xFF\xFE raw\n")
        result = runner_for(dir).send(:run_git, 'git', 'show', '--stat', 'HEAD')

        expect(result[:stdout].encoding).to eq(Encoding::UTF_8)
        expect(result[:stdout].valid_encoding?).to be true
      end
    end
  end

  describe '#relative_to_workdir' do
    it 'passes a workdir-relative path through unchanged' do
      Dir.mktmpdir do |dir|
        r = runner_for(dir)
        expect(r.send(:relative_to_workdir, 'lib/foo.rb')).to eq('lib/foo.rb')
        expect(r.send(:relative_to_workdir, './lib/x.rb')).to eq('lib/x.rb')
      end
    end

    it 'resolves ".." before relativizing, so a nested path is normalized' do
      Dir.mktmpdir do |dir|
        expect(runner_for(dir).send(:relative_to_workdir, 'lib/../spec/a.rb'))
          .to eq('spec/a.rb')
      end
    end

    # git cannot express a path outside the repo root relative to it, so the
    # canonical absolute path is what reaches the "--" filter.
    it 'leaves a path outside the working directory absolute' do
      Dir.mktmpdir do |dir|
        r   = runner_for(dir)
        abs = r.send(:relative_to_workdir, '../out.rb')
        expect(abs).to eq(File.expand_path('../out.rb', dir))
        expect(abs).not_to include('..')
      end
    end
  end

  describe '#clamp_limit' do
    it 'falls back to the default for a missing or non-positive limit' do
      Dir.mktmpdir do |dir|
        r = runner_for(dir)
        expect(r.send(:clamp_limit, nil, 300)).to eq(300)
        expect(r.send(:clamp_limit, 0, 300)).to eq(300)
        expect(r.send(:clamp_limit, -3, 300)).to eq(300)
      end
    end

    it 'keeps a usable limit and caps anything above MAX_LIMIT' do
      Dir.mktmpdir do |dir|
        r = runner_for(dir)
        expect(r.send(:clamp_limit, 40, 300)).to eq(40)
        expect(r.send(:clamp_limit, '7', 300)).to eq(7)
        expect(r.send(:clamp_limit, 100_000, 300)).to eq(GitRunner::MAX_LIMIT)
      end
    end
  end

  describe '#truncate_output' do
    # split("\n", -1): the trailing empty field survives, so a file ending in a
    # newline counts its final blank line and the notice matches what the user
    # sees, instead of keeping one line more than the limit.
    it 'counts a trailing newline as a line' do
      Dir.mktmpdir do |dir|
        text, truncated = runner_for(dir).send(:truncate_output, "a\nb\n", 2)

        expect(truncated).to be true
        expect(text).to eq("a\nb\n... (output truncated: 1 more line(s) omitted - " \
                           "narrow the query or raise 'limit' to see them)")
      end
    end

    it 'returns short output untouched' do
      Dir.mktmpdir do |dir|
        text, truncated = runner_for(dir).send(:truncate_output, "a\nb\n", 3)
        expect(text).to eq("a\nb\n")
        expect(truncated).to be false
      end
    end
  end

  describe '#git_error' do
    it 'names the git subcommand and the exit status, and appends the hint' do
      Dir.mktmpdir do |dir|
        msg = runner_for(dir).send(
          :git_error, 'diff',
          { status: 128, stdout: '', stderr: "fatal: bad revision 'x'\nsecond line\n" },
          'check that the revision exists'
        )

        expect(msg).to eq("error: git diff failed (exit 128): fatal: bad revision 'x'. " \
                          'check that the revision exists')
      end
    end

    # git writes some failures on stdout, so the caller cannot assume stderr is
    # where the reason lives.
    it 'falls back to stdout when stderr is empty' do
      Dir.mktmpdir do |dir|
        msg = runner_for(dir).send(:git_error, 'diff',
                                   { status: 1, stdout: 'only stdout here', stderr: '' })
        expect(msg).to eq('error: git diff failed (exit 1): only stdout here')
      end
    end

    it 'says so when the command produced no message at all' do
      Dir.mktmpdir do |dir|
        msg = runner_for(dir).send(:git_error, 'log', { status: 1, stdout: '', stderr: '' })
        expect(msg).to eq('error: git log failed (exit 1): no error message')
      end
    end

    it 'takes only the first line of a multi-line git message' do
      Dir.mktmpdir do |dir|
        msg = runner_for(dir).send(:git_error, 'grep',
                                   { status: 128, stdout: '', stderr: "line one\nline two\n" })
        expect(msg).to eq('error: git grep failed (exit 128): line one')
      end
    end

    # Issue #40: the fail line goes over the task's event queue, and with no Task
    # active it is a no-op - never a write from the tool thread.
    it 'routes the status line and never writes to $stdout' do
      Dir.mktmpdir do |dir|
        expect {
          runner_for(dir).send(:git_error, 'diff', { status: 1, stdout: '', stderr: 'x' })
        }.not_to output.to_stdout
      end
    end
  end

  describe 'the status-line shadow the class warns about' do
    # Tool#status is inherited by every git tool, so run_git must not create a
    # local named "status" - it would shadow the emitter for the rest of the body.
    it 'keeps Tool#status callable after run_git' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        r      = runner_for(dir)
        result = r.send(:run_git, 'git', 'status', '--short')

        expect(result[:status]).to eq(0)
        expect(r.status(:ok, 'still callable')).to be_nil
      end
    end
  end

  describe 'DEFAULT_LIMITS' do
    it 'is one entry per git subcommand, each small enough for the context window' do
      expect(GitRunner::DEFAULT_LIMITS)
        .to eq({ diff: 500, show: 1000, status: 200, log: 200, grep: 300, apply: 100 })
    end
  end
end
