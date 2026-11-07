# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'image_store'

RSpec.describe ImageStore do
  # Every case gets its own scratch workdir: the store is created INSIDE the
  # block so the assertion about "what files exist in the store dir" describes
  # only that case's writes.
  def store(klass = described_class, **opts)
    Dir.mktmpdir do |dir|
      yield klass.new(dir, **opts), dir
    end
  end

  def save(store, server: 'blender', tool: 'get_screenshot',
           mime: 'image/png', bytes: "\x89PNG\x1a\n".b)
    store.save(server: server, tool: tool, mime_type: mime, bytes: bytes)
  end

  describe '#save (native bytes on disk)' do
    it 'writes the bytes UNENCODED and returns the workdir-relative path' do
      store do |store, workdir|
        bytes = [72, 13, 0, 255, 128].pack('C*').b # bytes no text encoding can hold

        relative = save(store, bytes: bytes)

        expect(relative).to eq('.harness/content/blender_get_screenshot_1.png')
        expect(File.binread(File.join(workdir, relative))).to eq(bytes)
      end
    end

    it 'never base64-encodes what it writes (the file is the artifact, not a transport form)' do
      store do |store, workdir|
        relative = save(store, bytes: 'plain'.b)

        expect(File.binread(File.join(workdir, relative))).to eq('plain')
      end
    end

    it 'numbers successive blobs so one tool calling twice does not overwrite itself' do
      store do |store, _workdir|
        first  = save(store, bytes: 'a'.b)
        second = save(store, bytes: 'b'.b)

        expect(first).to eq('.harness/content/blender_get_screenshot_1.png')
        expect(second).to eq('.harness/content/blender_get_screenshot_2.png')
      end
    end

    it 'creates the store directory when it does not exist yet' do
      store do |store, workdir|
        save(store)

        expect(File.directory?(File.join(workdir, '.harness/content'))).to be(true)
      end
    end

    it 'returns nil when the write fails (a failed spill must not break the turn)' do
      store do |store|
        allow(File).to receive(:binwrite).and_raise(Errno::EACCES)

        expect(save(store)).to be_nil
      end
    end
  end

  describe 'name safety (a tool name comes from a remote server)' do
    it 'replaces every character outside the safe set, so a separator cannot escape the store' do
      store do |store, workdir|
        relative = save(store, server: '../../evil', tool: "a/b\nc", mime: 'image/png')

        # Dots survive (they are legal in a basename) but every separator is
        # gone, so the name stays ONE component inside the store.
        expect(relative).to eq('.harness/content/.._.._evil_a_b_c_1.png')
        expect(File.exist?(File.join(workdir, relative))).to be(true)
        expect(Dir.entries(File.join(workdir, '.harness/content')).sort)
          .to eq(['.', '..', '.._.._evil_a_b_c_1.png'])
      end
    end

    it 'truncates a very long name' do
      store do |store, _workdir|
        relative = save(store, server: 'x' * 200, tool: 't')

        expect(File.basename(relative)).to eq("#{'x' * 40}_t_1.png")
      end
    end
  end

  describe 'extension from mime type' do
    it 'maps a subtype to an extension' do
      store do |store, _workdir|
        expect(save(store, mime: 'image/jpeg')).to end_with('.jpeg')
      end
    end

    it 'falls back to .bin for an unknown or missing subtype instead of guessing' do
      store do |store, _workdir|
        expect(save(store, mime: 'application/octet-stream')).to end_with('.bin')
        expect(save(store, mime: 'image/')).to end_with('.bin')
        expect(save(store, mime: nil)).to end_with('.bin')
      end
    end
  end

  describe 'dir (per-session blob dirs)' do
    it 'honours an explicit dir and reports it as the relative dir' do
      store(dir: '.harness/content/sess-42') do |store, _workdir|
        relative = save(store, server: 's', tool: 't')

        expect(store.relative_dir).to eq('.harness/content/sess-42')
        expect(relative).to eq('.harness/content/sess-42/s_t_1.png')
      end
    end

    it 'defaults to the harness content dir' do
      expect(described_class.new('/tmp/x').relative_dir).to eq(ImageStore::DEFAULT_DIR)
    end
  end

  describe '#harness_state? (what the model must be told)' do
    it 'is true for a path under harness state: the file tools will not open it' do
      expect(described_class.new('/w').harness_state?('.harness/content/s_t_1.png')).to be(true)
    end

    it 'is false for a path the file tools may read, so no misleading note is added' do
      expect(described_class.new('/w').harness_state?('build/out/s_t_1.png')).to be(false)
    end
  end
end
