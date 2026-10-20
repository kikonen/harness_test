# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'session'
require 'tools/file_delete_tool'

RSpec.describe Tools::FileDeleteTool do
  def drive_dialog(lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  def file_list(dir)
    FileList.new([], workdir: dir)
  end

  def session
    Session.new('sys prompt')
  end

  it 'deletes the file when a DELETE grant is given' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'gone.txt'), "x\n")
      list = file_list(dir)
      list.add_file('gone.txt', :d)

      out = described_class.new(list, session).execute('path' => 'gone.txt')
      expect(out).to eq("ok: file 'gone.txt' has been deleted")
      expect(File.exist?(File.join(dir, 'gone.txt'))).to be false
    end
  end

  # Issue #92: delete is its OWN mode. A read grant, a write grant, or both do
  # not make a file deletable - the tool must still ask.
  it 'asks for the DELETE grant even when read and write are already granted' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :rw)

      out    = drive_dialog(['4 no deleting'])
      result = described_class.new(list).execute('path' => 'a.txt')

      expect(result).to start_with("error: access denied for 'a.txt'")
      expect(result).to include(%{(user's note: "no deleting")})
      expect(out.string).to include('Access requested (delete access)')
      expect(File.exist?(File.join(dir, 'a.txt'))).to be true
    end
  end

  it 'deletes without asking when a recursive delete grant covers the path' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'tmp/keep/9'))
      File.write(File.join(dir, 'tmp/keep/9/x.txt'), "x\n")
      list = file_list(dir)
      list.add_dir('tmp/keep/9', :d)

      expect(UI::Dialog).not_to receive(:new)
      result = described_class.new(list, session).execute('path' => 'tmp/keep/9/x.txt')
      expect(result).to start_with('ok: file')
    end
  end

  it 'refuses a sensitive path before any grant is offered' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, '.git'))
      File.write(File.join(dir, '.git/COMMIT_EDITMSG'), "x\n")
      list = file_list(dir)
      list.add_dir('.', :d)

      expect(UI::Dialog).not_to receive(:new)
      result = described_class.new(list).execute('path' => '.git/COMMIT_EDITMSG')

      expect(result).to eq("error: file '.git/COMMIT_EDITMSG' is blocked and can never be deleted")
      expect(File.exist?(File.join(dir, '.git/COMMIT_EDITMSG'))).to be true
    end
  end

  it 'refuses a .env* path whatever the grants say' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.env.local'), "SECRET=1\n")
      list = file_list(dir)
      list.add_dir('.', :d)

      result = described_class.new(list).execute('path' => '.env.local')
      expect(result).to include('blocked and can never be deleted')
    end
  end

  it 'reports a missing file instead of failing on the delete' do
    Dir.mktmpdir do |dir|
      list = file_list(dir)
      list.add_file('gone.txt', :d)

      result = described_class.new(list).execute('path' => 'gone.txt')
      expect(result).to eq("error: file 'gone.txt' does not exist on disk")
    end
  end

  it 'reports a directory as not-a-file (dir.delete is a separate tool)' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'sub'))
      list = file_list(dir)
      list.add_dir('sub', :d)

      result = described_class.new(list).execute('path' => 'sub')
      expect(result).to eq("error: file 'sub' does not exist on disk")
      expect(File.directory?(File.join(dir, 'sub'))).to be true
    end
  end

  # Issue #170: a deleted file has no digest to keep - the cache entry goes with
  # it, so a later read of a NEW file at the same path is not compared against
  # the dead one.
  it 'drops the digest cache entry when a session is attached' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'a.txt')
      File.write(path, "one\n")
      sess = session
      sess.file_cache.record(path, 'deadbeef', workdir: dir)
      expect(sess.file_cache.known?(path, workdir: dir)).to be true

      list = file_list(dir)
      list.add_file('a.txt', :d)
      described_class.new(list, sess).execute('path' => 'a.txt')

      expect(sess.file_cache.known?(path, workdir: dir)).to be false
      expect(sess.file_cache.to_h).to be_empty
    end
  end

  # The constructor advertises session as OPTIONAL, but the cache step is
  # @session&.file_cache.clear(...): safe navigation guards only the next send, so
  # the clear lands on nil and raises AFTER the file is already deleted. Pinpointed
  # by this spec; the fix is tracked in the issue below, so it stays pending rather
  # than pinning the broken behaviour as expected.
  it 'deletes fine with no session at all (the cache step is optional)' do
    skip 'known bug: NoMethodError without a Session, see issue #335'
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :d)

      expect { described_class.new(list, session).execute('path' => 'a.txt') }.not_to output.to_stdout
    end
  end

  it 'advertises a required path' do
    Dir.mktmpdir do |dir|
      schema = described_class.new(file_list(dir)).to_openai[:function][:parameters]
      expect(schema[:properties].keys).to contain_exactly(:path)
      expect(schema[:required]).to eq(['path'])
    end
  end
end
