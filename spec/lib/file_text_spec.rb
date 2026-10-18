# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'file_text'

RSpec.describe FileText do
  def analyze(bytes)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'f.txt')
      File.binwrite(path, bytes)
      FileText.from_disk(path)
    end
  end

  describe '.from_disk' do
    it 'reports LF as the style of a pure-LF file' do
      r = analyze("a\nb\n")
      expect(r.separator).to eq("\n")
      expect(r.lone_cr).to eq(0)
      expect(r.mixed).to eq(false)
      expect(r.lossy).to eq(false)
    end

    it 'reports CRLF as the style of a pure-CRLF file' do
      # The point of this file: a text-mode File.read of these bytes has already
      # dropped every CR, so the style is only visible in the bytes.
      r = analyze("a\r\nb\r\n")
      expect(r.separator).to eq("\r\n")
      expect(r.lone_cr).to eq(0)
    end

    it 'gives the model LF-only text whatever the file used' do
      expect(analyze("a\r\nb\r\n").text).to eq("a\nb\n")
      expect(analyze("a\nb\n").text).to eq("a\nb\n")
    end

    it 'counts a CR that is not part of a CRLF as damage' do
      r = analyze("a\r\r\nb\r\n")
      expect(r.lone_cr).to eq(1)
      expect(r.mixed).to eq(false)
      expect(r.text).to eq("a\nb\n")  # the stray CR is deleted, never a blank line
    end

    it 'keeps the line count when damage is present' do
      expect(analyze("a\r\r\nb\r\n").text.lines.size).to eq(2)
    end

    it 'picks the majority style of a mixed file' do
      expect(analyze("a\r\nb\r\nc\n").separator).to eq("\r\n")
      expect(analyze("a\nb\r\nc\n").separator).to eq("\n")
    end

    it 'marks a mixed file as needing repair' do
      expect(FileText.dirty?(analyze("a\r\nb\r\nc\n"))).to eq(true)
      expect(FileText.dirty?(analyze("a\r\nb\r\n"))).to eq(false)
    end

    it 'treats a CR-only file as its own style, not as damage' do
      r = analyze("a\rb\r")
      expect(r.separator).to eq("\r")
      expect(r.lone_cr).to eq(0)
      expect(FileText.dirty?(r)).to eq(false)
    end

    it 'reports the trailing separator exactly (a trailing blank line is content)' do
      expect(analyze("a\nb\n").trailing_newline).to eq(true)
      expect(analyze("a\nb\n\n").trailing_newline).to eq(true)
      expect(analyze("a\nb").trailing_newline).to eq(false)
      expect(analyze('').trailing_newline).to eq(false)
    end

    it 'flags bytes that are not valid UTF-8 as lossy' do
      r = analyze(['a', "\xE4", "b\n"].join.b)
      expect(r.lossy).to eq(true)
      expect(r.text).to eq("a?b\n")
    end
  end

  describe '.write' do
    it 'writes the requested separator byte for byte' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'f.txt')
        FileText.write(path, "a\nb\n", "\r\n")
        expect(File.binread(path)).to eq("a\r\nb\r\n")
        FileText.write(path, "a\nb\n", "\n")
        expect(File.binread(path)).to eq("a\nb\n")
      end
    end

    it 'leaves the text untouched when the separator is LF' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'f.txt')
        FileText.write(path, "a\nb\n", "\n")
        expect(File.binread(path)).to eq("a\nb\n")
      end
    end
  end

  describe '.from_text' do
    it 'analyses model-supplied content with the same rules' do
      r = FileText.from_text("a\r\r\nb\r\n")
      expect(r.lone_cr).to eq(1)
      expect(r.text).to eq("a\nb\n")
      expect(r.separator).to eq("\r\n")
    end
  end

  describe '.repair_note' do
    it 'names what the source already carried' do
      expect(FileText.repair_note(analyze("a\r\r\nb\r\n"))).to eq('1 bare CR normalized to CRLF')
      expect(FileText.repair_note(analyze("a\r\nb\r\nc\n"))).to eq('mixed CRLF/LF normalized to CRLF')
    end

    it 'names the separator the file will actually be written with' do
      mixed_lf_majority = analyze("a\nb\r\nc\n")
      expect(FileText.repair_note(mixed_lf_majority, "\r\n")).to eq('mixed CRLF/LF normalized to CRLF')
    end
  end
end
