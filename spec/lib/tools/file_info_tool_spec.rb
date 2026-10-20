# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'tools/file_info_tool'

RSpec.describe Tools::FileInfoTool do
  def drive_dialog(lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  # Sizes are asserted in BYTES, so every fixture is written with binwrite: a text
  # File.write on Windows rewrites "\n" as CRLF and changes the size the tool
  # reports (issue #318's line-ending rule applies to the fixtures too).
  def granted_list(dir)
    list = FileList.new([], workdir: dir)
    list.add_file('a.txt', :r)
    list
  end

  def info_for(dir, name = 'a.txt', list: nil)
    described_class.new(list || granted_list(dir)).execute('path' => name)
  end

  describe 'the metadata block' do
    it 'reports path, size, modified time, permissions and line count' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), "one\ntwo\n")
        out = info_for(dir)

        expect(out).to include('path: a.txt')
        expect(out).to include('size: 8 B (8 bytes)')
        expect(out).to match(/modified: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)
        expect(out).to match(/permissions: [rwx-]{9}/)
        expect(out).to include('lines: 2')
      end
    end

    # "Without reading its contents" is the point of the tool: it answers for a file
    # whose bytes are not text at all.
    it 'does not read the file contents' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), "\x00\x01\x02binary")
        out = info_for(dir)

        expect(out.valid_encoding?).to be true
        expect(out).not_to include('binary')
        expect(out).to include('size: 9 B (9 bytes)')
      end
    end

    it 'reports an empty file as zero lines' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), '')
        expect(info_for(dir)).to include('size: 0 B (0 bytes)').and include('lines: 0')
      end
    end

    # count_lines iterates the file, so a last line with no trailing newline counts.
    it 'counts a last line that has no trailing newline' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), "one\ntwo")
        expect(info_for(dir)).to include('lines: 2')
      end
    end
  end

  describe 'human_size' do
    it 'switches units at 1024 and keeps one decimal' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), 'x' * 1500)
        expect(info_for(dir)).to include('size: 1.5 KB (1500 bytes)')
      end
    end

    it 'stays in bytes just under 1024 and is exactly 1.0 KB at the boundary' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), 'x' * 1023)
        expect(info_for(dir)).to include('size: 1023 B (1023 bytes)')

        File.binwrite(File.join(dir, 'a.txt'), 'x' * 1024)
        expect(info_for(dir)).to include('size: 1.0 KB (1024 bytes)')
      end
    end

    it 'steps up to MB and never past GB' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), 'x' * (3 * 1024 * 1024))
        expect(info_for(dir)).to include('size: 3.0 MB')
      end
    end
  end

  describe 'format_permissions' do
    # The rendering rule is asserted on the helper directly: on Windows chmod is a
    # no-op and File.stat reports whatever the filesystem decides (measured: always
    # rw-r--r--), so a fixture cannot produce an executable mode there.
    it 'renders the mode bits as three rwx groups' do
      tool = described_class.new(FileList.new([], workdir: Dir.pwd))
      expect(tool.send(:format_permissions, 0o644)).to eq('rw-r--r--')
      expect(tool.send(:format_permissions, 0o755)).to eq('rwxr-xr-x')
      expect(tool.send(:format_permissions, 0o600)).to eq('rw-------')
      expect(tool.send(:format_permissions, 0o444)).to eq('r--r--r--')
    end

    # The mode is masked to 0o777 and left-padded, so a one-digit mode is the
    # OTHERS bits only: 0o7 -> "007" -> ------rwx.
    it 'masks and left-pads a short mode' do
      tool = described_class.new(FileList.new([], workdir: Dir.pwd))
      expect(tool.send(:format_permissions, 0o7)).to eq('------rwx')
    end

    it 'always renders nine characters on a real file' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), "x\n")
        expect(info_for(dir)).to match(/permissions: [rwx-]{9}/)
      end
    end
  end

  describe 'grants and blocks' do
    it 'asks for read access and forwards the denial note' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), "x\n")
        drive_dialog(['4 I did not ask for that'])

        result = described_class.new(FileList.new([], workdir: dir)).execute('path' => 'a.txt')
        expect(result).to start_with("error: access denied for 'a.txt'")
        expect(result).to include(%{(user's note: "I did not ask for that")})
      end
    end

    it 'answers from a write grant alone (write implies read on the same path)' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'a.txt'), "x\n")
        list = FileList.new([], workdir: dir)
        list.add_file('a.txt', :w)

        expect(UI::Dialog).not_to receive(:new)
        expect(described_class.new(list).execute('path' => 'a.txt')).to include('lines: 1')
      end
    end

    # This tool has no explicit sensitive? branch of its own: a sensitive path is not
    # readable, so it comes back as a plain denial rather than the "blocked" wording
    # file.copy / file.delete use. Same outcome, different message.
    it 'refuses a sensitive path without opening any dialog' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, '.env'), "SECRET=1\n")
        list = FileList.new([], workdir: dir)
        list.add_dir('.', :r)

        expect(UI::Dialog).not_to receive(:new)
        expect(described_class.new(list).execute('path' => '.env'))
          .to eq("error: access denied for '.env'")
      end
    end

    it 'reports a missing file' do
      Dir.mktmpdir do |dir|
        expect(info_for(dir)).to eq('error: file not found: a.txt')
      end
    end

    # file.info is for files; a directory is reported as not found (file.list is the
    # listing tool).
    it 'reports a directory as not found' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'sub'))
        list = FileList.new([], workdir: dir)
        list.add_dir('sub', :r)

        expect(described_class.new(list).execute('path' => 'sub'))
          .to eq('error: file not found: sub')
      end
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, 'a.txt'), "x\n")
      expect { info_for(dir) }.not_to output.to_stdout
    end
  end

  it 'advertises a required path' do
    Dir.mktmpdir do |dir|
      schema = described_class.new(FileList.new([], workdir: dir)).to_openai[:function][:parameters]
      expect(schema[:properties].keys).to contain_exactly(:path)
      expect(schema[:required]).to eq(['path'])
    end
  end
end
