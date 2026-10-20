# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'file_list'
require 'tools/git_grep_tool'

GREP_GIT_ENV = {
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

RSpec.describe Tools::GitGrepTool do

  # Two commits that differ in one line each, so a pattern can match one commit
  # and not the other - the point of `git log -G`.
  def setup_repo(dir)
    File.write(File.join(dir, 'a.txt'), "alpha\nkeep\n")
    system(GREP_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
    system(GREP_GIT_ENV, 'git', 'add', 'a.txt', chdir: dir, exception: true)
    system(GREP_GIT_ENV, 'git', 'commit', '-q', '-m', 'adds alpha', chdir: dir, exception: true)

    File.write(File.join(dir, 'a.txt'), "beta\nkeep\n")
    system(GREP_GIT_ENV, 'git', 'commit', '-q', '-am', 'alpha becomes beta', chdir: dir, exception: true)
  end

  def tool_for(dir)
    described_class.new(FileList.new([], workdir: dir))
  end

  it 'finds the commit whose diff contains the pattern' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      out = tool_for(dir).execute('pattern' => 'alpha')

      expect(out).to include('adds alpha')
      expect(out).to include('alpha becomes beta') # the removal line counts too
    end
  end

  it 'reports no commits when nothing matches' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect(tool_for(dir).execute('pattern' => 'zzznompattern'))
        .to eq("no commits found matching 'zzznompattern'")
    end
  end

  it 'requires a non-empty pattern' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect(tool_for(dir).execute('pattern' => '   '))
        .to eq("error: 'pattern' is required and must not be empty")
    end
  end

  # -G matches the diff text case-sensitively; the flag is the tool's answer when
  # the caller only remembers the word, not its spelling.
  it 'is case-sensitive by default and case-insensitive with ignore_case' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect(tool_for(dir).execute('pattern' => 'ALPHA'))
        .to include("no commits found matching 'ALPHA'")

      out = tool_for(dir).execute('pattern' => 'ALPHA', 'ignore_case' => true)
      expect(out).to include('adds alpha')
    end
  end

  # -G takes a regex, and a character class or "." work as expected.
  it 'accepts a regular expression, not only a literal word' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect(tool_for(dir).execute('pattern' => '[bB]eta')).to include('alpha becomes beta')
      expect(tool_for(dir).execute('pattern' => 'alph.'))
        .to include('adds alpha').and include('alpha becomes beta')
    end
  end

  # Measured: git's -G regex is applied to the diff as ONE block, so a "^" is
  # anchored to the start of that block and a line-anchored pattern finds nothing.
  it 'matches the regex against the diff as a whole block, not per line' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect(tool_for(dir).execute('pattern' => '^[-+]beta'))
        .to eq("no commits found matching '^[-+]beta'")
    end
  end

  describe 'max_count' do
    # Measured: --max-count limits the commits git OUTPUTS, and -G filtering
    # happens during the walk - so a small max_count bounds the number of matches
    # shown, not how far back the history is scanned.
    it 'bounds the matching commits shown, not how far back the walk goes' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        # "keep" appears only in the OLDEST commit's diff, and max_count 1 still
        # reaches it: the walk continues until one match is found.
        out = tool_for(dir).execute('pattern' => 'keep', 'max_count' => 1)
        expect(out).to include('adds alpha')
        expect(out.lines.size).to eq(1)
      end
    end

    it 'defaults to DEFAULT_MAX_COUNT for a missing, zero or negative value' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        [0, -7, nil].each do |bad|
          out = tool_for(dir).execute('pattern' => 'keep', 'max_count' => bad)
          expect(out).not_to start_with('error:')
        end
        expect(described_class::DEFAULT_MAX_COUNT).to eq(300)
      end
    end
  end

  describe 'a path filter' do
    it 'restricts the search to commits touching that file' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        File.write(File.join(dir, 'b.txt'), "gamma\n")
        system(GREP_GIT_ENV, 'git', 'add', 'b.txt', chdir: dir, exception: true)
        system(GREP_GIT_ENV, 'git', 'commit', '-q', '-m', 'adds gamma', chdir: dir, exception: true)

        out = tool_for(dir).execute('pattern' => 'gamma', 'path' => 'b.txt')
        expect(out).to include('adds gamma')
        expect(out).not_to include('adds alpha')
      end
    end
  end

  # git log in a repository with no commits is a git failure (exit 128), so the
  # "no commits found" fallback cannot cover that case.
  it 'reports a repository with no commits as a git failure' do
    Dir.mktmpdir do |dir|
      system(GREP_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
      out = tool_for(dir).execute('pattern' => 'anything')

      expect(out).to start_with("error: git grep 'anything' failed (exit 128):")
      expect(out).to include('does not have any commits yet')
    end
  end

  it 'truncates a long result to the limit and names the dropped lines' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      # Both commits match "alph."; git's pretty format emits no trailing newline, so
      # limit 1 keeps the newest line and reports the one it dropped.
      out = tool_for(dir).execute('pattern' => 'alph.', 'limit' => 1)
      expect(out.lines.first).to include('alpha becomes beta')
      expect(out.lines.first).not_to include('adds alpha')
      expect(out.lines.size).to eq(2) # 1 kept + the notice
      expect(out).to include('output truncated: 1 more line(s) omitted')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect { tool_for(dir).execute('pattern' => 'alpha') }.not_to output.to_stdout
    end
  end

  it 'advertises the grep parameters with pattern required' do
    Dir.mktmpdir do |dir|
      schema = tool_for(dir).to_openai[:function][:parameters]
      expect(schema[:properties].keys)
        .to contain_exactly(:pattern, :path, :ignore_case, :max_count, :limit)
      expect(schema[:required]).to eq(['pattern'])
    end
  end
end
