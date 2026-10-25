# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'session'
require 'tools/file_rename_tool'

RSpec.describe Tools::FileRenameTool do
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

  def granted_list(dir, old: 'a.txt', new: 'b.txt')
    list = file_list(dir)
    list.add_file(old, :w)
    list.add_file(new, :w)
    list
  end

  it 'moves the file when write is granted on both paths' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "content\n")
      list = granted_list(dir)

      out = described_class.new(list, session).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')
      expect(out).to eq('ok: renamed a.txt to b.txt')
      expect(File.read(File.join(dir, 'b.txt'))).to eq("content\n")
      expect(File.exist?(File.join(dir, 'a.txt'))).to be false
    end
  end

  # Renaming MOVES the bytes: contents (and their exact line endings) must not be
  # rewritten on the way, which is what "the digest travels with the file" relies on.
  it 'keeps the bytes exact' do
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, 'a.txt'), "crlf\r\nmixed\nlast")
      list = granted_list(dir)

      described_class.new(list, session).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')
      expect(File.binread(File.join(dir, 'b.txt'))).to eq("crlf\r\nmixed\nlast")
    end
  end

  # Issue #170: the cache is re-keyed, not copied - so the file keeps its digest
  # under the new path and no stale entry is left under the old one.
  it 're-keys the digest cache entry so the digest travels with the file' do
    Dir.mktmpdir do |dir|
      old = File.join(dir, 'a.txt')
      new = File.join(dir, 'b.txt')
      File.write(old, "content\n")
      sess = session
      digest = FileList.sha256(old)
      sess.file_cache.record(old, digest, workdir: dir)

      list = granted_list(dir)
      described_class.new(list, sess).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')

      expect(sess.file_cache.digest(new, workdir: dir)).to eq(digest)
      expect(sess.file_cache.known?(old, workdir: dir)).to be false
      expect(sess.file_cache.to_h.keys).to eq(['b.txt'])
    end
  end

  it 'renames without a cached entry (nothing to move, no stale key created)' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      sess = session
      list = granted_list(dir)

      described_class.new(list, sess).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')
      expect(sess.file_cache.to_h).to be_empty
    end
  end

  it 'asks for the write grant on the file being moved' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('b.txt', :w)

      drive_dialog(['4'])
      result = described_class.new(list, session).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')

      expect(result).to start_with("error: access denied for 'a.txt'")
      expect(File.exist?(File.join(dir, 'a.txt'))).to be true
    end
  end

  # The move CREATES the destination, so it needs its own write grant - a grant on
  # the source alone is not enough.
  it 'asks for the write grant on the destination separately' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :w)

      out    = drive_dialog(['4 wrong place'])
      result = described_class.new(list, session).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')

      expect(result).to start_with("error: write access denied for 'b.txt'")
      expect(result).to include(%{(user's note: "wrong place")})
      expect(out.string).to include('Access requested (write access): b.txt')
      expect(File.exist?(File.join(dir, 'a.txt'))).to be true
    end
  end

  it 'refuses a sensitive destination before any grant is offered' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :w)

      expect(UI::Dialog).not_to receive(:new)
      result = described_class.new(list, session).execute('old_path' => 'a.txt', 'new_path' => '.env')

      expect(result).to eq("error: new path '.env' is blocked and can never be written")
      expect(File.exist?(File.join(dir, 'a.txt'))).to be true
    end
  end

  it 'refuses a source that does not exist' do
    Dir.mktmpdir do |dir|
      list = granted_list(dir)

      result = described_class.new(list, session).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')
      expect(result).to eq("error: file 'a.txt' does not exist on disk")
    end
  end

  it 'refuses when the destination already exists (a move must not overwrite)' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "src\n")
      File.write(File.join(dir, 'b.txt'), "keep me\n")
      list = granted_list(dir)

      result = described_class.new(list, session).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')
      expect(result).to eq("error: destination 'b.txt' already exists - choose a different new path")
      expect(File.read(File.join(dir, 'a.txt'))).to eq("src\n")
      expect(File.read(File.join(dir, 'b.txt'))).to eq("keep me\n")
    end
  end

  it 'creates the destination directory when it does not exist yet' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :w)
      list.add_dir('sub/deep', :w)

      out = described_class.new(list, session).execute('old_path' => 'a.txt',
                                                       'new_path' => 'sub/deep/b.txt')
      expect(out).to eq('ok: renamed a.txt to sub/deep/b.txt')
      expect(File.file?(File.join(dir, 'sub/deep/b.txt'))).to be true
    end
  end

  # session is OPTIONAL here, and the cache re-keying is a Session's own business,
  # so no session means nothing to re-key. The one-hop guard @session&.file_cache
  # called .rename on nil AFTER the file had already moved (&. covers only the NEXT
  # send), so the model was told a successful rename had failed (issue #335).
  it 'renames fine with no session at all (the cache step is optional)' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "content\n")
      list = granted_list(dir)

      out = described_class.new(list).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')

      expect(out).to eq('ok: renamed a.txt to b.txt')
      expect(File.read(File.join(dir, 'b.txt'))).to eq("content\n")
      expect(File.exist?(File.join(dir, 'a.txt'))).to be false
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = granted_list(dir)

      expect {
        described_class.new(list, session).execute('old_path' => 'a.txt', 'new_path' => 'b.txt')
      }.not_to output.to_stdout
    end
  end

  it 'advertises old_path and new_path as required' do
    Dir.mktmpdir do |dir|
      schema = described_class.new(file_list(dir)).to_openai[:function][:parameters]
      expect(schema[:properties].keys).to contain_exactly(:old_path, :new_path)
      expect(schema[:required]).to contain_exactly('old_path', 'new_path')
    end
  end
end
