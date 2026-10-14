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
