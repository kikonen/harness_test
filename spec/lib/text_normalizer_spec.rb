# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'text_normalizer'

# External text (shell output, file reads, model-supplied tool-call arguments,
# git output) can carry bytes that are not valid UTF-8, or be tagged with a
# code page. Downstream String operations then raise ArgumentError ("invalid
# byte sequence in UTF-8") on strip/split/gsub/regex, concatenation with a
# UTF-8 literal raises Encoding::CompatibilityError, and JSON.generate raises
# JSON::GeneratorError - so the failure is invisible (the session save that
# should record it dies on the same byte). This is the single read-boundary
# normalizer (issue #257 / #233).
RSpec.describe TextNormalizer do
  # Byte sequences are built with pack so the SPEC SOURCE itself stays
  # pure ASCII: a literal invalid byte in this file would break the file
  # read/patch tools (and the harness' own tooling) on UTF-8 hosts.
  def bytes(*b)
    b.pack('C*')
  end

  describe '.normalize' do
    it 'returns valid UTF-8 text untouched (and still frozen)' do
      text = 'hello world'
      expect(described_class.normalize(text)).to equal(text)
      expect(described_class.normalize(text)).to be_frozen
    end

    it 'replaces bytes that cannot be represented in UTF-8' do
      # UTF-8-tagged but byte-invalid: an incomplete 2-byte sequence.
      bad = bytes(0xE2, 0x80).force_encoding(Encoding::UTF_8)
      expect(bad.valid_encoding?).to be false
      expect(described_class.normalize(bad)).to eq('?')
    end

    it 'replaces unrepresentable bytes in a BINARY-tagged string' do
      # What a pipe/pipe-chunk yields when default_external is a code page.
      bin = bytes(97, 144, 98)
      expect(described_class.normalize(bin)).to eq('a?b')
    end

    it 'transcodes text tagged with another encoding when its bytes are valid' do
      # CP850 0x80 is a legal character there, so it must survive as the
      # character rather than being replaced.
      cp850 = bytes(0x80).force_encoding('CP850')
      expect(cp850.valid_encoding?).to be true
      result = described_class.normalize(cp850)
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result.valid_encoding?).to be true
      expect(result.bytes).to eq([195, 135]) # UTF-8 'C with cedilla'
    end

    it 'makes the operations that raise on raw input safe' do
      bad = bytes(0xE2, 0x80).force_encoding(Encoding::UTF_8)
      # The raw string is the control: these are the documented raise sites.
      expect { bad.strip }.to raise_error(ArgumentError)
      expect { bad.split(' ') }.to raise_error(ArgumentError)
      expect { bad.match?(/x/) }.to raise_error(ArgumentError)

      safe = described_class.normalize(bad)
      expect(safe.strip).to eq('?')
      expect(safe.split(' ')).to eq(['?'])
      expect(safe.match?(/x/)).to be false
      expect(safe.inspect).to eq('"?"')
    end

    it 'lets JSON.generate succeed on text that would raise' do
      bad = bytes(0xE2, 0x80).force_encoding(Encoding::UTF_8)
      expect { JSON.generate({ 'a' => bad }) }.to raise_error(JSON::GeneratorError)
      expect(JSON.generate({ 'a' => described_class.normalize(bad) })).to eq('{"a":"?"}')
    end

    # issue #268: a BINARY tag is a BYTE CONTAINER, not a text encoding (it
    # is what the child pipe accumulator holds, #257). Encoding from BINARY
    # maps every byte separately, so a valid UTF-8 multi-byte character was
    # destroyed one byte at a time - native non-ASCII text came out as '?'
    # runs and became unreadable. The bytes must be read as UTF-8 first.
    describe 'BINARY-tagged bytes (issue #268)' do
      it 'keeps a 2-byte character that arrived through the BINARY accumulator' do
        # The reported case: the localized wc -c total line (a word ending in
        # 'a' WITH a diaeresis, UTF-8 C3 A4) reached the model as that letter
        # replaced by two question marks, i.e. the word was unreadable.
        source = bytes(0x79, 0x68, 0x74, 0x65, 0x65, 0x6E, 0x73, 0xC3, 0xA4)
        accumulator = source.dup.force_encoding(Encoding::BINARY)
        result = described_class.normalize(accumulator)

        expect(result.bytes).to eq(source.bytes)
        expect(result.encoding).to eq(Encoding::UTF_8)
      end

      it 'keeps a 3-byte character (one byte became three question marks)' do
        acc = bytes(0xE2, 0x9C, 0x93).force_encoding(Encoding::BINARY)
        expect(described_class.normalize(acc).bytes).to eq([0xE2, 0x9C, 0x93])
      end

      it 'keeps a character split across two pipe chunks' do
        # The accumulator joins raw chunks, so a character can straddle the
        # 64K readpartial boundary - only the WHOLE buffer is decodable, which
        # is why normalization happens once, at the end.
        first  = bytes(0x61, 0xC3).force_encoding(Encoding::BINARY)
        second = bytes(0xA4, 0x62).force_encoding(Encoding::BINARY)
        expect(described_class.normalize(first + second).bytes)
          .to eq([0x61, 0xC3, 0xA4, 0x62])
      end

      it 'still replaces bytes that are not valid UTF-8 in the accumulator' do
        # The #257 guarantee is intact: a truncated sequence must not survive
        # as raw bytes, it becomes the printable replacement.
        acc = bytes(0x61, 0xE2, 0x80, 0x62).force_encoding(Encoding::BINARY)
        expect(described_class.normalize(acc)).to eq('a?b')
      end
    end

    # The code-page fallback must never treat BINARY as an encoding:
    # transcoding FROM a BINARY tag is the byte-by-byte mangling
    # normalize_bytes exists to avoid, so a BINARY default_external must fall
    # through to the scrub path instead.
    it 'never falls back to a BINARY default_external (issue #268)' do
      acc = bytes(0xE4).force_encoding(Encoding::BINARY) # not valid UTF-8
      begin
        encoding_before = Encoding.default_external
        Encoding.default_external = Encoding::BINARY
        expect(described_class.normalize(acc)).to eq('?')
      ensure
        Encoding.default_external = encoding_before
      end
    end

    # The return type is the contract: every consumer (JSON session save,
    # concatenation with the tool's own UTF-8 literals) assumes valid UTF-8,
    # so a result tagged with any other encoding is a bug even when it is
    # technically a valid string.
    it 'returns UTF-8 even when the input is byte-invalid in its OWN code page' do
      shift_jis = bytes(0x82).force_encoding('Shift_JIS') # a lone lead byte
      expect(shift_jis.valid_encoding?).to be false
      result = described_class.normalize(shift_jis)
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result.valid_encoding?).to be true
      expect { result + 'literal' }.not_to raise_error
    end

    it 'returns UTF-8 for every encoding tag shape it can be handed' do
      inputs = [
        bytes(0xC3, 0xA4),                                    # UTF-8, valid
        bytes(0xE2, 0x80).force_encoding(Encoding::UTF_8),    # UTF-8, invalid
        bytes(0xFF).force_encoding(Encoding::BINARY),         # BINARY, invalid
        bytes(0xC3, 0xA4).force_encoding(Encoding::BINARY),   # BINARY, valid UTF-8
        bytes(0x80).force_encoding('CP850'),                  # code page, valid
        bytes(0x82).force_encoding('Shift_JIS')               # code page, invalid
      ]
      inputs.each do |input|
        result = described_class.normalize(input)
        expect(result.encoding).to eq(Encoding::UTF_8)
        expect(result.valid_encoding?).to be true
      end
    end
  end

  describe '.normalize_strings' do
    it 'normalizes every String inside a parsed JSON structure' do
      bad = bytes(0xE2, 0x80).force_encoding(Encoding::UTF_8)
      obj = { 'a' => [bad, 1], 'b' => nil, 'c' => { 'd' => bad } }
      cleaned = described_class.normalize_strings(obj)

      expect { JSON.generate(obj) }.to raise_error(JSON::GeneratorError)
      expect(JSON.generate(cleaned)).to eq('{"a":["?",1],"b":null,"c":{"d":"?"}}')
    end

    it 'leaves non-string values and the structure shape alone' do
      obj = { 'n' => 1, 's' => 'ok', 'arr' => [nil, true, 'x'] }
      expect(described_class.normalize_strings(obj)).to eq(obj)
    end

    it 'returns the object unchanged when nothing is a String' do
      expect(described_class.normalize_strings(42)).to eq(42)
    end
  end
end
