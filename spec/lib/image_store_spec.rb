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

    it 'does not clobber a blob from a resumed run that reused the session dir' do
      # A resume rebuilds the store (fresh @count = 0) but keeps the same dir,
      # so its first spill would otherwise reuse the earlier run's _1 name.
      Dir.mktmpdir do |workdir|
        dir    = '.harness/content/sess-42'
        before = described_class.new(workdir, dir: dir)
        before.save(server: 'blender', tool: 'get_screenshot',
                    mime_type: 'image/png', bytes: 'old'.b)

        after = described_class.new(workdir, dir: dir)
        relative = after.save(server: 'blender', tool: 'get_screenshot',
                              mime_type: 'image/png', bytes: 'new'.b)

        expect(relative).to eq("#{dir}/blender_get_screenshot_2.png")
        expect(File.binread(File.join(workdir, "#{dir}/blender_get_screenshot_1.png")))
          .to eq('old')
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

  def save_named(store, name: 'photo', mime: 'image/png', bytes: 'a'.b)
    store.save_named(name: name, mime_type: mime, bytes: bytes)
  end

  describe '#save_named (a blob the caller already has a real name for)' do
    it 'keeps the caller name and puts the mime extension after the index' do
      store do |store, workdir|
        relative = save_named(store)

        # The <name>_<index>.<ext> shape: a file that ends in a real extension,
        # not <name>.<ext>_<index> (which would leave the blob with a numeric
        # extension a viewer cannot open).
        expect(relative).to eq('.harness/content/photo_1.png')
        expect(File.binread(File.join(workdir, relative))).to eq('a')
      end
    end

    it 'strips an extension the caller name carried, so the mime decides the only one' do
      store do |store, _workdir|
        # A name that already said ".png" and a mime that also said .png: the
        # extension must not double to photo.png_1.png.
        expect(save_named(store, name: 'photo.png')).to end_with('_1.png')
        expect(File.basename(save_named(store, name: 'photo.png')))
          .to eq('photo_2.png')
      end
    end

    it 'uses the MIME extension even when the name disagreed' do
      store do |store, _workdir|
        # The name claimed .png but the bytes are a JPEG; the stored file must
        # say what the bytes actually are.
        expect(save_named(store, name: 'photo.png', mime: 'image/jpeg'))
          .to eq('.harness/content/photo_1.jpeg')
      end
    end

    it 'falls back to .bin for a non-image mime, exactly like save' do
      store do |store, _workdir|
        expect(save_named(store, name: 'thing', mime: 'application/octet-stream'))
          .to end_with('_1.bin')
      end
    end

    it 'reduces a name carrying a path to its final safe component' do
      store do |store, workdir|
        relative = save_named(store, name: 'dir/../../evil.png')

        # No ".." and no separator survives: the blob stays ONE component inside
        # the store, never a write outside it.
        expect(File.basename(relative)).to eq('evil_1.png')
        expect(Dir.entries(File.join(workdir, '.harness/content')).sort)
          .to eq(['.', '..', 'evil_1.png'])
      end
    end

    it 'replaces a lost name with a fallback instead of an empty stem' do
      store do |store, _workdir|
        # ".png" is all extension, no stem; nil and blank must not yield "_1.png"
        # (a nameless blob a session cannot reason about).
        expect(File.basename(save_named(store, name: '.png'))).to eq('image_1.png')
        expect(File.basename(save_named(store, name: nil))).to eq('image_2.png')
      end
    end

    it 'truncates a very long name to the same budget save enforces' do
      store do |store, _workdir|
        expect(File.basename(save_named(store, name: 'x' * 200))).to eq("#{'x' * 40}_1.png")
      end
    end

    it 'bumps past an index a resumed run already wrote (issue #276 rule)' do
      Dir.mktmpdir do |workdir|
        dir    = '.harness/content/sess-42'
        before = described_class.new(workdir, dir: dir)
        before.save_named(name: 'photo.png', mime_type: 'image/png', bytes: 'old'.b)

        after = described_class.new(workdir, dir: dir)
        relative = after.save_named(name: 'photo.png', mime_type: 'image/png', bytes: 'new'.b)

        expect(relative).to eq("#{dir}/photo_2.png")
        expect(File.binread(File.join(workdir, "#{dir}/photo_1.png"))).to eq('old')
      end
    end

    it 'returns nil when the write fails' do
      store do |store|
        allow(File).to receive(:binwrite).and_raise(Errno::EACCES)

        expect(save_named(store)).to be_nil
      end
    end
  end
end
