# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'tools/file_search_tool'

RSpec.describe Tools::FileSearchTool do
  # issue #257: the content read from disk is the read boundary. A file whose
  # bytes are not valid UTF-8 made the tool's own split / regex match raise
  # (String#split and Regexp#match? both raise ArgumentError on invalid
  # bytes), and the matched lines that reach the LLM - and the session JSON
  # save - carried the same byte. Normalizing first makes the whole path safe.
  describe 'invalid UTF-8 bytes (issue #257)' do
    def bad_bytes
      [0xE2, 0x90].pack('C*').force_encoding(Encoding::UTF_8)
    end

    it 'matches a line containing an undecodable byte without raising' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'sample.txt'), "line1 ok\nline2 " + bad_bytes + "\n")

        list = FileList.new([], workdir: dir)
        list.add_dir(dir, :r)

        # Control: the raw read is what the tool's split/regex used to choke on.
        raw = File.read(File.join(dir, 'sample.txt'))
        expect(raw.valid_encoding?).to be false
        expect { raw.split("\n") }.to raise_error(StandardError)

        out = described_class.new(list).execute('pattern' => 'line2')
        expect(out).to eq('sample.txt:2: line2 ?')
        expect(out.valid_encoding?).to be true
        expect { JSON.generate({ 'result' => out }) }.not_to raise_error
      end
    end

    it 'still skips genuinely binary content (the NUL check runs on raw bytes)' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, 'bin.dat'), [0xE2, 0x90, 0x00, 0x61].pack('C*'))

        list = FileList.new([], workdir: dir)
        list.add_dir(dir, :r)

        expect(described_class.new(list).execute('pattern' => 'a'))
          .to eq('no matches for /a/')
      end
    end
  end
end
