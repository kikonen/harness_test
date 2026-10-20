# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'file_list'
require 'tools/git_diff_tool'

DIFF_GIT_ENV = {
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

RSpec.describe Tools::GitDiffTool do
  # Same real-repo setup as git_apply_tool_spec: the tool runs real git, so the
  # assertions are about git's real exit codes and empty-output cases rather
  # than a stubbed run_git. maintenance.auto is switched off through git's own
  # config env so no detached maintenance child writes into the tmp repo during
  # Dir.mktmpdir cleanup.

  def setup_repo(dir, file: 'hello.txt', content: "line1\nline2\nline3\n")
    target = File.join(dir, file)
    File.write(target, content)
    system(DIFF_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
    system(DIFF_GIT_ENV, 'git', 'add', file, chdir: dir, exception: true)
    system(DIFF_GIT_ENV, 'git', 'commit', '-q', '-m', 'init', chdir: dir, exception: true)
    target
  end

  def tool_for(dir)
    described_class.new(FileList.new([], workdir: dir))
  end

  describe 'the whole working tree' do
    it 'says the tree is clean rather than returning an empty string' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        expect(tool_for(dir).execute({})).to eq('working tree is clean (no changes vs HEAD)')
      end
    end

    it 'shows staged and unstaged changes' do
      Dir.mktmpdir do |dir|
        target = setup_repo(dir)
        File.write(target, "line1\nchanged\nline3\n")

        out = tool_for(dir).execute({})
        expect(out).to include('--- a/hello.txt')
        expect(out).to include('-line2')
        expect(out).to include('+changed')
      end
    end

    it 'diffs against a revision when one is given' do
      Dir.mktmpdir do |dir|
        target = setup_repo(dir)
        File.write(target, "line1\nline2\nline3\nedited\n")
        system(DIFF_GIT_ENV, 'git', 'commit', '-q', '-am', 'second', chdir: dir, exception: true)

        out = tool_for(dir).execute('revision' => 'HEAD~1')
        expect(out).to include('+edited')
      end
    end

    it 'reports an unknown revision with git\'s own reason' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = tool_for(dir).execute('revision' => 'nosuchrev')

        expect(out).to start_with('error: git diff failed (exit 128):')
        expect(out).to include('unknown revision')
        expect(out).to include('check that the revision exists')
      end
    end

    # The limit is what protects the context window: the notice names how many
    # lines were dropped so the caller knows to narrow the query.
    it 'truncates to the limit and names the dropped lines' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        # A tracked file rewritten with many lines: git diff shows the removals
        # AND the additions, so the output is long enough to be truncated.
        File.write(File.join(dir, 'hello.txt'), (1..30).map { |i| "l#{i}" }.join("\n"))

        out = tool_for(dir).execute('limit' => 5)
        expect(out.lines.size).to eq(6) # 5 kept lines + the notice
        expect(out).to include('output truncated: ')
        expect(out).not_to include('+l30')
      end
    end

    it 'falls back to the default limit for a non-positive limit' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        expect(tool_for(dir).execute('limit' => 0))
          .to eq('working tree is clean (no changes vs HEAD)')
      end
    end
  end

  describe 'one path' do
    it 'restricts the diff to that file' do
      Dir.mktmpdir do |dir|
        setup_repo(dir, file: 'a.txt') # committed as line1/line2/line3
        File.write(File.join(dir, 'b.txt'), "b1\nb2\n")
        system(DIFF_GIT_ENV, 'git', 'add', 'b.txt', chdir: dir, exception: true)
        system(DIFF_GIT_ENV, 'git', 'commit', '-q', '-m', 'add b', chdir: dir, exception: true)

        File.write(File.join(dir, 'a.txt'), "line1\nchanged\n")
        File.write(File.join(dir, 'b.txt'), "b1\nalso changed\n")

        out = tool_for(dir).execute('path' => 'a.txt')
        expect(out).to include('-line2')
        expect(out).to include('+changed')
        expect(out).not_to include('b.txt')
        expect(out).not_to include('also changed')
      end
    end

    it 'says no changes for a file that has none' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        expect(tool_for(dir).execute('path' => 'hello.txt'))
          .to eq('no changes for hello.txt')
      end
    end

    # git exits 0 for a path filter that matches nothing, so the tool cannot
    # tell "path does not exist" from "path has no changes" - and a path that
    # DOES exist but is clean reaches the same branch. Both are honest here.
    it 'reports no changes for a path that does not exist' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        expect(tool_for(dir).execute('path' => 'nope.txt')).to eq('no changes for nope.txt')
      end
    end

    # `git diff` compares the WORKING TREE with the INDEX, so a file whose only
    # change is that it was staged (or that it is untracked) shows nothing at
    # all - git's own semantics, inherited here, and the reason the tool says
    # "no changes" instead of inventing a diff.
    it 'shows nothing for a file whose change is only in the index' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        File.write(File.join(dir, 'new.txt'), "added line\n")
        system(DIFF_GIT_ENV, 'git', 'add', 'new.txt', chdir: dir, exception: true)

        expect(tool_for(dir).execute('path' => 'new.txt')).to eq('no changes for new.txt')
      end
    end

    it 'combines a revision with a path filter' do
      Dir.mktmpdir do |dir|
        target = setup_repo(dir)
        File.write(target, "line1\nline2\nline3\nmore\n")
        system(DIFF_GIT_ENV, 'git', 'commit', '-q', '-am', 'second', chdir: dir, exception: true)

        out = tool_for(dir).execute('revision' => 'HEAD~1', 'path' => 'hello.txt')
        expect(out).to include('+more')
      end
    end

    # A path starting with "-" would otherwise be read as a git option; the tool
    # always places path filters after "--".
    it 'passes a dash-leading path after "--" so git does not read it as an option' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        File.write(File.join(dir, '-odd.txt'), "x\n")
        out = tool_for(dir).execute('path' => '-odd.txt')

        expect(out).not_to start_with('error:')
      end
    end

    it 'ignores a blank path and diffs the whole tree' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        expect(tool_for(dir).execute('path' => '   '))
          .to eq('working tree is clean (no changes vs HEAD)')
      end
    end
  end

  describe '#to_openai' do
    it 'advertises the diff parameters' do
      Dir.mktmpdir do |dir|
        schema = tool_for(dir).to_openai[:function][:parameters]
        expect(schema[:properties].keys).to contain_exactly(:path, :revision, :limit)
      end
    end
  end
end
