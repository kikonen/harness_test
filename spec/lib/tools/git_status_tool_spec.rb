# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'file_list'
require 'tools/git_status_tool'

STATUS_GIT_ENV = {
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

RSpec.describe Tools::GitStatusTool do
  def setup_repo(dir, file: 'hello.txt', content: "line1\nline2\n")
    target = File.join(dir, file)
    File.write(target, content)
    system(STATUS_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)
    system(STATUS_GIT_ENV, 'git', 'add', file, chdir: dir, exception: true)
    system(STATUS_GIT_ENV, 'git', 'commit', '-q', '-m', 'init', chdir: dir, exception: true)
    target
  end

  def tool_for(dir)
    described_class.new(FileList.new([], workdir: dir))
  end

  # --short --branch is what makes the output self-describing: the branch header
  # is always present even for a clean tree, so the output is never empty and
  # the tool's own "working tree is clean" fallback cannot be reached here.
  it 'answers a clean tree with the branch header and no status lines' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect(tool_for(dir).execute({})).to eq("## master\n")
    end
  end

  it 'reports each change with its porcelain status code under the branch' do
    Dir.mktmpdir do |dir|
      target = setup_repo(dir)
      File.write(target, "line1\nchanged\n")
      File.write(File.join(dir, 'new.txt'), "untracked\n")

      out = tool_for(dir).execute({})
      expect(out).to start_with('## ')
      expect(out).to include(' M hello.txt')
      expect(out).to include('?? new.txt')
    end
  end

  it 'shows a staged change with its index status' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      File.write(File.join(dir, 'staged.txt'), "new\n")
      system(STATUS_GIT_ENV, 'git', 'add', 'staged.txt', chdir: dir, exception: true)

      expect(tool_for(dir).execute({})).to include('A  staged.txt')
    end
  end

  it 'shows a deleted file with its status code' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      File.delete(File.join(dir, 'hello.txt'))

      expect(tool_for(dir).execute({})).to include('D hello.txt')
    end
  end

  # An empty repository is not an error: git answers with its own header, and
  # the tool passes it through rather than reporting a failure.
  it 'reports an empty repository by its branch header, not as an error' do
    Dir.mktmpdir do |dir|
      system(STATUS_GIT_ENV, 'git', 'init', '-q', chdir: dir, exception: true)

      out = tool_for(dir).execute({})
      expect(out).not_to start_with('error:')
      expect(out).to include('## ')
    end
  end

  it 'truncates a long status to the limit and names the dropped lines' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      20.times { |i| File.write(File.join(dir, "f#{i}.txt"), "x\n") }

      out = tool_for(dir).execute('limit' => 3)
      # The branch header is itself one of the kept lines, so the limit eats into
      # the status lines: header + 2 files, then the notice. The count includes
      # git's trailing blank line (GitRunner#truncate_output splits with -1).
      expect(out.lines.first(3)).to eq(["## master\n", "?? f0.txt\n", "?? f1.txt\n"])
      expect(out).to include('output truncated: 19 more line(s) omitted')
    end
  end

  it 'falls back to the default limit for a non-positive limit' do
    Dir.mktmpdir do |dir|
      setup_repo(dir)
      expect(tool_for(dir).execute('limit' => -5)).to eq("## master\n")
    end
  end

  # The status line is routed over the task's event queue (issue #40): with no
  # Task active it is a no-op, never a write from the tool thread.
  it 'never writes to $stdout' do
    Dir.mktmpdir do |dir|
      expect { tool_for(dir).execute({}) }.not_to output.to_stdout
    end
  end

  it 'advertises only the limit parameter (status takes no path filter)' do
    Dir.mktmpdir do |dir|
      schema = tool_for(dir).to_openai[:function][:parameters]
      expect(schema[:properties].keys).to contain_exactly(:limit)
    end
  end
end
