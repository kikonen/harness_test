# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/file_image_tool'

RSpec.describe Tools::FileImageTool do
  def drive_dialog(*lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  def png(dir, name = 'shot.png')
    path = File.join(dir, name)
    # A real PNG head so the sniffer recognizes it; the payload after the magic
    # is arbitrary (the sniffer decides on the leading bytes alone).
    File.binwrite(path, "\x89PNG\r\n\x1A\n".b + "IEND-ish payload".b)
    path
  end

  # A workdir with a read grant on it, so the tool runs with no consent dialog
  # (the file tools' own consent is covered by file_list_spec / file_read specs).
  def tool_with_grant(dir)
    list = FileList.new([], workdir: dir)
    list.add_dir(dir, :r)
    described_class.new(list)
  end

  describe 'the tool contract' do
    it 'is named file.image and takes a path' do
      Dir.mktmpdir do |dir|
        tool = tool_with_grant(dir)

        expect(tool.name).to eq('file.image')
        expect(tool.parameters[:required]).to eq(['path'])
        expect(tool.parameters[:properties].keys).to eq([:path])
      end
    end

    it 'tells the model it reads from disk and sniffs the real type' do
      Dir.mktmpdir do |dir|
        text = tool_with_grant(dir).to_openai[:function][:description]

        expect(text).to include('disk')
        expect(text).to include('sniffed')
        expect(text).to include('file.read')
      end
    end
  end

  describe 'reading a disk image' do
    it 'returns a ToolResult whose Image carries the disk path as a reference' do
      Dir.mktmpdir do |dir|
        png(dir, 'shot.png')

        result = tool_with_grant(dir).execute('path' => 'shot.png')

        expect(result).to be_a(ToolResult)
        expect(result.text).to include('shot.png')
        expect(result.text).to include('image/png')
        image = result.images.first
        expect(image.mime_type).to eq('image/png')
        # reference (not name_hint): delivery must point at the original file
        # the model can already open, instead of spilling a duplicate copy.
        expect(image.reference).to eq('shot.png')
        expect(image.name_hint).to be_nil
        expect(image.bytes).to include("\x89PNG".b)
      end
    end

    # The reference is the workdir-relative path the model was given as the
    # argument - the same one it could pass to a shell tool to act on the file.
    it 'names the reference relative to the working directory' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'assets'))
        png(dir, 'assets/render.png')

        result = tool_with_grant(dir).execute('path' => 'assets/render.png')

        expect(result.images.first.reference).to eq('assets/render.png')
      end
    end

    it 'sniffs the type from the bytes, not from the extension' do
      Dir.mktmpdir do |dir|
        # A JPEG saved under a .txt name: file.read would mangle it, and the
        # sniffer must still report image/jpeg from the magic bytes.
        File.binwrite(File.join(dir, 'photo.txt'), "\xFF\xD8\xFF\xE0".b + "payload".b)

        result = tool_with_grant(dir).execute('path' => 'photo.txt')

        expect(result).to be_a(ToolResult)
        expect(result.images.first.mime_type).to eq('image/jpeg')
      end
    end
  end

  describe 'refusals that must read as errors, not as a broken image' do
    it 'refuses a path that does not exist' do
      Dir.mktmpdir do |dir|
        out = tool_with_grant(dir).execute('path' => 'missing.png')

        expect(out).to be_a(String)
        expect(out).to include('not found')
      end
    end

    it 'refuses a file that is not a recognized image' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'notes.txt'), "plain text, not an image\n")

        out = tool_with_grant(dir).execute('path' => 'notes.txt')

        expect(out).to be_a(String)
        expect(out).to include('not a recognized image')
        expect(out).to include('file.read')
      end
    end

    # The bytes (not the name) decide: a 0-byte file has no signature, so it is
    # not an image, and the model is pointed at file.read instead.
    it 'refuses an empty file' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'empty.png'), ''.b)

        expect(tool_with_grant(dir).execute('path' => 'empty.png'))
          .to include('not a recognized image')
      end
    end

    it 'runs the read grant/consent rule file.read uses' do
      Dir.mktmpdir do |dir|
        png(dir, 'secret.png')
        tool = described_class.new(FileList.new([], workdir: dir))
        drive_dialog("3 not relevant\n")

        out = tool.execute('path' => 'secret.png')

        expect(out).to start_with("error: access denied for 'secret.png'")
        expect(out).to include('user\'s note: "not relevant"')
      end
    end
  end
end
