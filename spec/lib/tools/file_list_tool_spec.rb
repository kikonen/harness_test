# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'file_list'
require 'tools/file_list_tool'

RSpec.describe Tools::FileListTool do
  def drive_dialog(lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  def tree(dir)
    FileUtils.mkdir_p(File.join(dir, 'lib/tools'))
    FileUtils.mkdir_p(File.join(dir, 'spec'))
    File.write(File.join(dir, 'lib/a.rb'), "x\n")
    File.write(File.join(dir, 'lib/tools/b.rb'), "x\n")
    File.write(File.join(dir, 'spec/c_spec.rb'), "x\n")
    File.write(File.join(dir, 'top.txt'), "x\n")
  end

  describe 'the pattern' do
    it 'lists every file a recursive glob matches, workdir-relative' do
      Dir.mktmpdir do |dir|
        tree(dir)
        list = FileList.new([], workdir: dir)
        list.add_dir('lib', :r)

        out = described_class.new(list).execute('pattern' => 'lib/**/*.rb')
        expect(out).to eq("- lib/a.rb\n- lib/tools/b.rb")
      end
    end

    it 'reports no match rather than an empty result' do
      Dir.mktmpdir do |dir|
        tree(dir)
        list = FileList.new([], workdir: dir)
        list.add_dir('.', :r)

        expect(described_class.new(list).execute('pattern' => 'nope/*'))
          .to include("no files match 'nope/*' under")
      end
    end

    it 'rejects an empty pattern with the usage line' do
      Dir.mktmpdir do |dir|
        list = FileList.new([], workdir: dir)
        expect(described_class.new(list).execute('pattern' => '  '))
          .to eq('error: usage: file.list(pattern)')
      end
    end

    # Directories are not files: a recursive glob lists the files under them only.
    it 'lists files, never directories' do
      Dir.mktmpdir do |dir|
        tree(dir)
        list = FileList.new([], workdir: dir)
        list.add_dir('.', :r)

        out = described_class.new(list).execute('pattern' => '**/*')
        lines = out.split("\n")
        expect(lines).not_to include('- lib')
        expect(lines).not_to include('- lib/tools')
        expect(lines).to include('- lib/tools/b.rb')
      end
    end
  end

  describe 'access' do
    # Listing needs READ on the directory the pattern points at; here that is the
    # glob's own base directory, not the working directory. A directory grant offers
    # flat (1), recursive (2), Cancel (3).
    it 'asks for read access on the base directory of the pattern' do
      Dir.mktmpdir do |dir|
        tree(dir)
        out    = drive_dialog(['2']) # recursive
        result = described_class.new(FileList.new([], workdir: dir)).execute('pattern' => 'lib/**/*.rb')

        expect(out.string).to include('Access requested (read access)')
        expect(result).to include('- lib/a.rb')
      end
    end

    it 'returns a denial (with the user note) when the listing is refused' do
      Dir.mktmpdir do |dir|
        tree(dir)
        drive_dialog(['3 not that tree'])
        result = described_class.new(FileList.new([], workdir: dir)).execute('pattern' => 'lib/**/*.rb')

        expect(result).to start_with("error: read access denied for directory 'lib'")
        expect(result).to include(%{(user's note: "not that tree")})
      end
    end

    it 'lists without asking when the base directory is already granted' do
      Dir.mktmpdir do |dir|
        tree(dir)
        list = FileList.new([], workdir: dir)
        list.add_dir('lib', :r)

        expect(UI::Dialog).not_to receive(:new)
        expect(described_class.new(list).execute('pattern' => 'lib/*.rb')).to eq('- lib/a.rb')
      end
    end

    # The base-directory check is about the DIRECTORY; each match is then filtered by
    # its OWN readable?. A grant on the directory path itself (a file grant, not a dir
    # grant) passes the check but covers none of the files, so nothing matches.
    it 'filters every match by its own read grant' do
      Dir.mktmpdir do |dir|
        tree(dir)
        list = FileList.new([], workdir: dir)
        list.add_file('lib', :r) # the dir path itself, not a recursive grant

        expect(UI::Dialog).not_to receive(:new)
        expect(described_class.new(list).execute('pattern' => 'lib/**/*.rb')).to include('no files match')
      end
    end

    # A recursive grant on the directory makes every file under it listable.
    it 'lists the whole subtree on a recursive directory grant' do
      Dir.mktmpdir do |dir|
        tree(dir)
        list = FileList.new([], workdir: dir)
        list.add_dir('lib', :r)

        expect(described_class.new(list).execute('pattern' => 'lib/**/*.rb'))
          .to eq("- lib/a.rb\n- lib/tools/b.rb")
      end
    end

    # Sensitive paths are never listable whatever the grants say.
    it 'excludes sensitive files from the results' do
      Dir.mktmpdir do |dir|
        tree(dir)
        File.write(File.join(dir, 'lib/.env'), "SECRET=1\n")
        FileUtils.mkdir_p(File.join(dir, 'lib/.git'))
        File.write(File.join(dir, 'lib/.git/config'), "x\n")
        list = FileList.new([], workdir: dir)
        list.add_dir('lib', :r)

        out = described_class.new(list).execute('pattern' => 'lib/*')
        expect(out).to eq('- lib/a.rb')
      end
    end

    # A pattern may not escape the working directory: the tool never grants a
    # listing outside the sandbox silently.
    it 'reports an outside pattern as no match rather than listing it' do
      Dir.mktmpdir do |dir|
        tree(dir)
        list = FileList.new([], workdir: dir)
        list.add_dir('.', :r)

        # The base directory is outside the workdir, so it is not covered by the
        # workdir grant and the tool asks (with its outside-path warning).
        out = drive_dialog(['2 outside is refused'])
        result = described_class.new(list).execute('pattern' => '../spec/*.rb')
        expect(result).to start_with('error: read access denied for directory')
        expect(out.string).to include('OUTSIDE the working directory')
      end
    end
  end

  describe 'MAX_RESULTS' do
    it 'caps the listing and names how many files were dropped' do
      Dir.mktmpdir do |dir|
        (1..(described_class::MAX_RESULTS + 10)).each do |i|
          File.write(File.join(dir, format('f%04d.txt', i)), "x\n")
        end
        list = FileList.new([], workdir: dir)
        list.add_dir('.', :r)

        out = described_class.new(list).execute('pattern' => 'f*.txt')
        expect(out.lines.count { |l| l.start_with?('- ') }).to eq(described_class::MAX_RESULTS)
        expect(out).to include("truncated: showing first #{described_class::MAX_RESULTS} of 510 files")
      end
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      tree(dir)
      list = FileList.new([], workdir: dir)
      list.add_dir('lib', :r)

      expect { described_class.new(list).execute('pattern' => 'lib/*.rb') }.not_to output.to_stdout
    end
  end

  it 'advertises a required pattern' do
    Dir.mktmpdir do |dir|
      schema = described_class.new(FileList.new([], workdir: dir)).to_openai[:function][:parameters]
      expect(schema[:properties].keys).to contain_exactly(:pattern)
      expect(schema[:required]).to eq(['pattern'])
    end
  end
end
