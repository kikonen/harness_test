# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'tools/file_copy_tool'

RSpec.describe Tools::FileCopyTool do
  # Grant dialogs are routed through the task to the main thread in production
  # (show(ui: nil)); here they are intercepted and served on a StringIO, the way
  # run_command_tool_spec does. Options for a file inside the workdir:
  # 1 = this file only, 2 = parent dir (dir only), 3 = parent dir (recursive),
  # 4 = Cancel.
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

  it 'copies a file once both grants are given' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "content\n")
      list = file_list(dir)
      list.add_file('a.txt', :r)
      list.add_file('b.txt', :w)

      out = described_class.new(list).execute('src' => 'a.txt', 'dst' => 'b.txt')
      expect(out).to eq('ok: copied a.txt to b.txt')
      expect(File.read(File.join(dir, 'b.txt'))).to eq("content\n")
      # The source survives: a copy is not a move.
      expect(File.exist?(File.join(dir, 'a.txt'))).to be true
    end
  end

  it 'creates the destination directory when it does not exist yet' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :r)
      list.add_dir('sub/deep', :w)

      out = described_class.new(list).execute('src' => 'a.txt', 'dst' => 'sub/deep/b.txt')
      expect(out).to eq('ok: copied a.txt to sub/deep/b.txt')
      expect(File.file?(File.join(dir, 'sub/deep/b.txt'))).to be true
    end
  end

  it 'asks for the read grant on the source and forwards the denial note' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      drive_dialog(["4 not the source I wanted"])

      result = described_class.new(file_list(dir)).execute('src' => 'a.txt', 'dst' => 'b.txt')
      expect(result).to start_with("error: access denied for 'a.txt'")
      expect(result).to include(%{(user's note: "not the source I wanted")})
    end
  end

  # The copy CREATES the destination, so it needs a WRITE grant there - a read
  # grant on both paths is not enough.
  it 'asks for the write grant on the destination even when the source is readable' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :r)

      out = drive_dialog(['4'])
      result = described_class.new(list).execute('src' => 'a.txt', 'dst' => 'b.txt')

      expect(result).to start_with("error: write access denied for 'b.txt'")
      expect(out.string).not_to include('already exists')
    end
  end

  # A sensitive name is blocked BEFORE any grant is offered: the destination can
  # never be written, whatever the user would answer.
  it 'refuses a sensitive destination without opening any dialog' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :rw)

      expect(UI::Dialog).not_to receive(:new)
      result = described_class.new(list).execute('src' => 'a.txt', 'dst' => '.env')

      expect(result).to eq("error: destination '.env' is blocked and can never be written")
      expect(File.exist?(File.join(dir, '.env'))).to be false
    end
  end

  it 'refuses to copy INTO a .git path whatever the grants say' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_dir('.', :rw)

      result = described_class.new(list).execute('src' => 'a.txt', 'dst' => '.git/HOOKS')
      expect(result).to start_with('error: destination')
      expect(result).to include('blocked and can never be written')
    end
  end

  it 'refuses when the source does not exist' do
    Dir.mktmpdir do |dir|
      list = file_list(dir)
      list.add_file('a.txt', :r)
      list.add_file('b.txt', :w)

      result = described_class.new(list).execute('src' => 'a.txt', 'dst' => 'b.txt')
      expect(result).to eq("error: source file 'a.txt' does not exist on disk")
    end
  end

  # The destination check exists because a copy must never silently overwrite.
  it 'refuses when the destination already exists' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "src\n")
      File.write(File.join(dir, 'b.txt'), "keep me\n")
      list = file_list(dir)
      list.add_file('a.txt', :r)
      list.add_file('b.txt', :w)

      result = described_class.new(list).execute('src' => 'a.txt', 'dst' => 'b.txt')
      expect(result).to eq("error: destination 'b.txt' already exists - choose a different path")
      expect(File.read(File.join(dir, 'b.txt'))).to eq("keep me\n")
    end
  end

  it 'refuses a directory as the source (it is not a file)' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'sub'))
      list = file_list(dir)
      list.add_dir('sub', :r)
      list.add_file('copy.txt', :w)

      result = described_class.new(list).execute('src' => 'sub', 'dst' => 'copy.txt')
      expect(result).to eq("error: source file 'sub' does not exist on disk")
    end
  end

  it 'keeps the bytes exact (no line-ending or encoding rewriting)' do
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, 'a.txt'), "crlf\r\nmixed\nlast")
      list = file_list(dir)
      list.add_file('a.txt', :r)
      list.add_file('b.txt', :w)

      described_class.new(list).execute('src' => 'a.txt', 'dst' => 'b.txt')
      expect(File.binread(File.join(dir, 'b.txt'))).to eq("crlf\r\nmixed\nlast")
    end
  end

  # Issue #40: the status lines go over the task's event queue, never a write
  # from the tool thread.
  it 'never writes to $stdout' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.txt'), "x\n")
      list = file_list(dir)
      list.add_file('a.txt', :rw)
      list.add_file('b.txt', :w)

      expect { described_class.new(list).execute('src' => 'a.txt', 'dst' => 'b.txt') }
        .not_to output.to_stdout
    end
  end

  it 'advertises src and dst as required' do
    Dir.mktmpdir do |dir|
      schema = described_class.new(file_list(dir)).to_openai[:function][:parameters]
      expect(schema[:properties].keys).to contain_exactly(:src, :dst)
      expect(schema[:required]).to contain_exactly('src', 'dst')
    end
  end
end
