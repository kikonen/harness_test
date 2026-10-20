# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'file_list'
require 'tools/git_show_tool'

SHOW_GIT_ENV = {
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

RSpec.describe Tools::GitShowTool do

  def setup_repo(dir, file: 'hello.txt', content: "line1\nline2\n")
    target = File.join(dir, file)
    File.write(target, content)
    system(SHOW_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
    system(SHOW_GIT_ENV, 'git', 'add', file, chdir: dir, exception: true)
    system(SHOW_GIT_ENV, 'git', 'commit', '-q', '-m', 'init', chdir: dir, exception: true)
    target
  end

  def second_commit(dir, file: 'hello.txt', content: "line1\nchanged\n")
    File.write(File.join(dir, file), content)
    system(SHOW_GIT_ENV, 'git', 'commit', '-q', '-am', 'second', chdir: dir, exception: true)
  end

  def tool_for(dir)
    described_class.new(FileList.new([], workdir: dir))
  end

  describe 'a commit without a path filter' do
    # Measured: `git show --stat` prints the message and the per-file stats and
    # NOT the patch (that needs --patch), so this path has no patch body.
    it 'defaults to HEAD: the message and per-file stats, no patch body' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        second_commit(dir)

        out = tool_for(dir).execute({})
        expect(out).to include('commit ')
        expect(out).to include('second')
        expect(out).to include('hello.txt | 2 +-')   # the --stat block
        expect(out).to include('1 file changed, 1 insertion(+), 1 deletion(-)')
        expect(out).not_to include('-line2')
      end
    end

    it 'accepts a revision, a tag, or a relative ref' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        system(SHOW_GIT_ENV, 'git', 'tag', 'v1', chdir: dir, exception: true)
        second_commit(dir)

        expect(tool_for(dir).execute('revision' => 'HEAD~1')).to include('init')
        expect(tool_for(dir).execute('revision' => 'v1')).to include('init')
        expect(tool_for(dir).execute('revision' => 'HEAD')).to include('second')
      end
    end

    it 'treats a blank revision as HEAD' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        expect(tool_for(dir).execute('revision' => '   ')).to include('init')
      end
    end

    it 'reports an unknown revision with git\'s reason and the hint' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = tool_for(dir).execute('revision' => 'nosuchrev')

        expect(out).to start_with('error: git show failed (exit 128):')
        expect(out).to include('unknown revision')
        expect(out).to include("check that 'nosuchrev' is a valid revision")
      end
    end
  end

  describe 'with a path filter' do
    it 'shows only that file\'s diff (git show takes no path filter itself)' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        File.write(File.join(dir, 'other.txt'), "x\n")
        system(SHOW_GIT_ENV, 'git', 'add', 'other.txt', chdir: dir, exception: true)
        system(SHOW_GIT_ENV, 'git', 'commit', '-q', '-m', 'adds other', chdir: dir, exception: true)
        second_commit(dir)

        out = tool_for(dir).execute('revision' => 'HEAD', 'path' => 'hello.txt')
        expect(out).to include('-line2')
        expect(out).not_to include('other.txt')
      end
    end

    # The root commit has NO parent, so `git diff HEAD^..HEAD` is a git error
    # (measured: exit 128, "bad revision 'HEAD^..HEAD'"). The tool falls back to
    # the well-known empty tree object, which is why EMPTY_TREE exists at all.
    it 'shows the root commit by falling back to the empty tree' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        out = tool_for(dir).execute('path' => 'hello.txt')

        expect(out).not_to start_with('error:')
        expect(out).to include('new file mode 100644')
        expect(out).to include('--- /dev/null')
        expect(out).to include('+line1')
      end
    end

    it 'says no changes for a path the commit did not touch' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        File.write(File.join(dir, 'other.txt'), "x\n")
        system(SHOW_GIT_ENV, 'git', 'add', 'other.txt', chdir: dir, exception: true)
        system(SHOW_GIT_ENV, 'git', 'commit', '-q', '-m', 'adds other', chdir: dir, exception: true)

        expect(tool_for(dir).execute('path' => 'hello.txt'))
          .to eq('no changes for hello.txt in HEAD')
      end
    end

    it 'truncates a long per-file diff to the limit' do
      Dir.mktmpdir do |dir|
        setup_repo(dir)
        File.write(File.join(dir, 'hello.txt'), (1..40).map { |i| "l#{i}" }.join("\n"))

        out = tool_for(dir).execute('limit' => 6)
        expect(out.lines.size).to eq(7) # 6 kept + the notice
        expect(out).to include('output truncated:')
      end
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect { tool_for(dir).execute({}) }.not_to output.to_stdout
    end
  end

  it 'advertises the show parameters' do
    Dir.mktmpdir do |dir|
      schema = tool_for(dir).to_openai[:function][:parameters]
      expect(schema[:properties].keys).to contain_exactly(:revision, :path, :limit)
    end
  end
end
