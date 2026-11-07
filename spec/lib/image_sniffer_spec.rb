# frozen_string_literal: true

require 'spec_helper'
require 'image_sniffer'

RSpec.describe ImageSniffer do
  # A leading signature plus trailing payload: real files carry bytes after the
  # magic number, and the sniffer must decide on the head alone.
  def file(bytes, filler = 'rest of the file')
    (bytes.b + filler.b)
  end

  describe '.sniff (the bytes decide, not the name or header)' do
    it 'identifies a PNG by its 8-byte signature' do
      expect(described_class.sniff("\x89PNG\r\n\x1A\n".b)).to eq('image/png')
      expect(described_class.sniff(file("\x89PNG\r\n\x1A\n"))).to eq('image/png')
    end

    it 'identifies an APNG by its chunk signature' do
      expect(described_class.sniff("\x1A\x44\x4E\x47".b)).to eq('image/png')
    end

    it 'identifies a JPEG (the shorter FFD8 FFD8 rule matches its own type)' do
      expect(described_class.sniff("\xFF\xD8\xFF\xE0".b)).to eq('image/jpeg')
    end

    it 'identifies a GIF by its versioned signature' do
      expect(described_class.sniff("GIF89a".b)).to eq('image/gif')
      expect(described_class.sniff("GIF87a".b)).to eq('image/gif')
    end

    it 'identifies a BMP and an ICO' do
      expect(described_class.sniff("BM".b)).to eq('image/bmp')
      expect(described_class.sniff("\x00\x00\x01\x00".b)).to eq('image/x-icon')
    end

    it 'returns nil for bytes that are not a known image signature' do
      expect(described_class.sniff("print 'hi'\n".b)).to be_nil
      expect(described_class.sniff('x'.b)).to be_nil
      expect(described_class.sniff(''.b)).to be_nil
      expect(described_class.sniff(nil)).to be_nil
    end

    # A PNG renamed .txt is still a PNG: the whole point of sniffing is that the
    # extension is not consulted.
    it 'ignores the extension entirely (a PNG renamed .txt is still a PNG)' do
      expect(described_class.sniff(file("\x89PNG\r\n\x1A\n"))).to eq('image/png')
    end

    # The sniffer is given whatever a reader handed it (a text-tagged string
    # after File.binread on some platforms, a BINARY-tagged one after a chunked
    # download), and it must compare BYTES either way, not re-encode them.
    it 'decides on bytes whatever the string is tagged as' do
      binary = "\x89PNG\r\n\x1A\n".b
      utf8   = "\x89PNG\r\n\x1A\n".dup.force_encoding(Encoding::UTF_8)

      expect(described_class.sniff(binary)).to eq('image/png')
      expect(described_class.sniff(utf8)).to eq('image/png')
    end
  end

  describe '.image_bytes?' do
    it 'is true for a recognized signature and false otherwise' do
      expect(described_class.image_bytes?("\xFF\xD8\xFF".b)).to be true
      expect(described_class.image_bytes?("plain text".b)).to be false
    end
  end

  describe '.image_content? (the header side)' do
    it 'is true for an image content-type, subtype and parameters included' do
      expect(described_class.image_content?('image/png')).to be true
      expect(described_class.image_content?('image/svg+xml')).to be true
      expect(described_class.image_content?('IMAGE/JPEG')).to be true
      expect(described_class.image_content?('image/webp; charset=binary')).to be true
    end

    it 'is false for a non-image type' do
      expect(described_class.image_content?('text/html')).to be false
      expect(described_class.image_content?('application/json')).to be false
      expect(described_class.image_content?('multipart/mixed')).to be false
    end

    # A response with NO Content-Type header yields nil from Net::HTTP. Calling
    # .strip on the nil split result raised - the sniffer must resolve a missing
    # header to "not an image", not crash the fetch.
    it 'is false (not an error) for a missing or empty content-type' do
      expect(described_class.image_content?(nil)).to be false
      expect(described_class.image_content?('')).to be false
      expect { described_class.image_content?(nil) }.not_to raise_error
    end
  end

  describe 'signature ordering' do
    # A JPEG begins with FFD8; the ICO signature is 00 00 01 00. Neither should
    # be shadowed by a looser rule that a shorter magic could accidentally match.
    it 'does not let one signature swallow another type' do
      expect(described_class.sniff("\xFF\xD8\xFF".b)).to eq('image/jpeg')
      expect(described_class.sniff("\x00\x00\x01\x00".b)).to eq('image/x-icon')
    end
  end
end
