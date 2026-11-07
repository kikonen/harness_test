# frozen_string_literal: true

require 'spec_helper'
require 'tool_result'

RSpec.describe ToolResult do
  def image(bytes: "\x89PNG".b, mime: 'image/png', server: 'srv', tool: 'shot')
    ToolResult::Image.new(server: server, tool: tool, mime_type: mime, bytes: bytes)
  end

  describe 'text' do
    it 'normalizes the text at the encoding boundary and is #to_s' do
      # A BINARY-tagged payload that is valid UTF-8: the chain may only hold
      # UTF-8 text (doc/encoding_design.md), and image bytes never enter it.
      result = described_class.new(text: "shot \xC3\xA4".b)

      expect(result.text).to eq("shot \xC3\xA4")
      expect(result.text.encoding).to eq(Encoding::UTF_8)
      expect(result.to_s).to eq("shot \xC3\xA4")
    end

    it 'replaces bytes that are not valid UTF-8 (the chain may only hold UTF-8)' do
      expect(described_class.new(text: "\xE2\x28".b).text).to eq("?(")
    end

    it 'defaults to empty text and no images' do
      result = described_class.new

      expect(result.text).to eq('')
      expect(result.images?).to be(false)
    end

    it 'reports images? when images are present' do
      result = described_class.new(text: 'shot', images: [image])

      expect(result.images?).to be(true)
      expect(result.to_s).to eq('shot')
    end
  end

  describe 'ToolResult::Image sizes' do
    it 'counts decoded bytes, not characters' do
      bytes = "\xC3\x28".b # 2 bytes, invalid UTF-8 as text

      expect(image(bytes: bytes).byte_size).to eq(2)
    end

    it 'reports the REAL base64 length (4 chars per 3 bytes, padded) - what a request body costs' do
      expect(image(bytes: "\x00".b).base64_size).to eq(Base64.strict_encode64("\x00".b).length)
      expect(image(bytes: "\x00\x00".b).base64_size).to eq(Base64.strict_encode64("\x00\x00".b).length)
      expect(image(bytes: ("\x00".b * 300)).base64_size).to eq(Base64.strict_encode64("\x00".b * 300).length)
    end

    it 'reports zero for an empty or missing payload' do
      expect(image(bytes: ''.b).base64_size).to eq(0)
      expect(image(bytes: nil).byte_size).to eq(0)
    end
  end

  describe '#summary' do
    it 'names sizes only - a log line never carries the payload' do
      result = described_class.new(
        text: 'shot', images: [image(bytes: 'abc'.b),
                               image(bytes: 'abcdefgh'.b, mime: 'image/jpeg')])

      expect(result.summary).to eq('text 4 chars, 2 image(s): image/png 3B, image/jpeg 8B')
      expect(result.summary).not_to include('abc')
    end

    it 'names only the text when there are no images' do
      expect(described_class.new(text: 'hello').summary).to eq('text 5 chars')
    end
  end

  # issue #451: the two OPTIONAL fields a non-MCP producer fills. A disk image
  # carries a reference (a path the model can already open); a download carries
  # a name_hint (spill it under a real name). ImageDelivery owns the behaviour
  # each one triggers - this only checks they are CARRIED.
  describe 'ToolResult::Image reference / name_hint (issue #451)' do
    it 'defaults both to nil (an MCP image fills neither)' do
      expect(image.reference).to be_nil
      expect(image.name_hint).to be_nil
    end

    it 'carries a disk reference' do
      disk = ToolResult::Image.new(server: 'file.image', tool: 'image',
                                   mime_type: 'image/png', bytes: 'x'.b,
                                   reference: 'build/shot.png')

      expect(disk.reference).to eq('build/shot.png')
      expect(disk.name_hint).to be_nil
    end

    it 'carries a name_hint for a download' do
      fetched = ToolResult::Image.new(server: 'web.fetch', tool: 'fetch',
                                      mime_type: 'image/png', bytes: 'x'.b,
                                      name_hint: 'logo.png')

      expect(fetched.name_hint).to eq('logo.png')
      expect(fetched.reference).to be_nil
    end
  end

  # NOT Array(images): Image is a Struct, and Array() on a Struct returns its
  # MEMBERS, so a lone image would silently become a list of Strings.
  describe 'a single Image (not an array)' do
    it 'stays an Image, not its members' do
      result = described_class.new(images: image)

      expect(result.images.size).to eq(1)
      expect(result.images.first).to be_a(ToolResult::Image)
      expect(result.images.first.bytes).to eq("\x89PNG".b)
    end
  end
end
