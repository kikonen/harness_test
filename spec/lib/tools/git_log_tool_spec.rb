# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'file_list'
require 'tools/git_log_tool'

LOG_GIT_ENV = {
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

RSpec.describe Tools::GitLogTool do

  def setup_repo(dir)
    File.write(File.join(dir, 'hello.txt'), "line1\nline2\n")
    system(LOG_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
    system(LOG_GIT_ENV, 'git', 'add', 'hello.txt', chdir: dir, exception: true)
    system(LOG_GIT_ENV, 'git', 'commit', '-q', '-m', 'first commit', chdir: dir, exception: true)
    File.write(File.join(dir, 'other.txt'), "alpha\n")
    system(LOG_GIT_ENV, 'git', 'add', 'other.txt', chdir: dir, exception: true)
    system(LOG_GIT_ENV, 'git', 'commit', '-q', '-m', 'second commit', chdir: dir, exception: true)
  end

  def tool_for(dir)
    described_class.new(FileList.new([], workdir: dir))
  end

  describe 'the compact format' do
    it 'prints one line per commit: short hash, author, date, subject' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = tool_for(dir).execute({})
        lines = out.split("\n")

        expect(lines.size).to eq(2)
        # git log lists NEWEST first, so the older commit is the LAST line.
        expect(lines.first).to match(/\A[0-9a-f]{7,} \| test \| \d{4}-\d{2}-\d{2} \| second commit\z/)
        expect(lines.last).to match(/\A[0-9a-f]{7,} \| test \| \d{4}-\d{2}-\d{2} \| first commit\z/)
      end
    end

    it 'shows the full diff when show_diff is on' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = tool_for(dir).execute('show_diff' => true)

        expect(out).to include('diff --git a/hello.txt')
        expect(out).to include('+line1')
      end
    end
  end

  describe 'max_count' do
    it 'bounds the number of commits' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = tool_for(dir).execute('max_count' => 1)

        expect(out.split("\n").size).to eq(1)
        expect(out).to include('second commit') # the most recent one
      end
    end

    # The tool's own default: a missing, zero or negative max_count would make
    # git show the whole history, which is the opposite of what a bounded query
    # asks for.
    it 'defaults to 30 for a missing, zero or negative value' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        %w[0 -5].each do |bad|
          out = tool_for(dir).execute('max_count' => bad.to_i)
          expect(out.split("\n").size).to eq(2)
        end
        expect(tool_for(dir).execute({})).to include('second commit')
      end
    end
  end

  describe 'a path filter' do
    it 'lists only commits touching that file' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = tool_for(dir).execute('path' => 'hello.txt')

        expect(out).to include('first commit')
        expect(out).not_to include('second commit')
      end
    end

    it 'says no commits touch a file the history never changed' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        # git log -- <path> exits 0 for an unknown path, so the tool reports it
        # as "no commits touching" rather than as a missing file.
        expect(tool_for(dir).execute('path' => 'never.txt'))
          .to eq('no commits touching never.txt')
      end
    end

    it 'reports a path git itself rejects' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = tool_for(dir).execute('path' => '../outside.txt')

        expect(out).to start_with('error: git log')
        expect(out).to include('check the path and that it exists in the repository history')
      end
    end
  end

  # git log in a repository with no commits is a git FAILURE (exit 128), not an
  # empty listing - so the tool reports it through git's own message and the
  # "no commits found" fallback is unreachable for this case.
  it 'reports a repository with no commits as a git failure' do
    Dir.mktmpdir do |dir|
      system(LOG_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
      out = tool_for(dir).execute({})

      expect(out).to start_with('error: git log failed (exit 128):')
      expect(out).to include('does not have any commits yet')
      expect(out).to include('check that you are inside a git repository with at least one commit')
    end
  end

  it 'truncates a long history to the limit and names the dropped lines' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      out = tool_for(dir).execute('show_diff' => true, 'limit' => 4)

      expect(out.lines.size).to eq(5) # 4 kept + the notice
      expect(out).to include('output truncated:')
    end
  end

  it 'is never a direct write to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect { tool_for(dir).execute({}) }.not_to output.to_stdout
    end
  end

  it 'advertises the log parameters' do
    Dir.mktmpdir do |dir|
      schema = tool_for(dir).to_openai[:function][:parameters]
      expect(schema[:properties].keys)
        .to contain_exactly(:max_count, :path, :show_diff, :limit)
    end
  end
end
