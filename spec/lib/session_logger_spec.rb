# frozen_string_literal: true

require 'spec_helper'
require 'session_logger'

# issue #548: SessionLogger is the single owner of a session log's Logger object.
# Two Loggers on one path lose ~10% of concurrent writes (each keeps its own file
# position - analysis/548), so every consumer of a path must read the SAME object.
RSpec.describe SessionLogger do
  it 'returns the same Logger for the same path (one writer per path)' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'harness.log')

      expect(described_class.build(path)).to equal(described_class.build(path))
    end
  end

  it 'returns distinct Loggers for distinct paths' do
    Dir.mktmpdir do |dir|
      a = described_class.build(File.join(dir, 'a', 'harness.log'))
      b = described_class.build(File.join(dir, 'b', 'harness.log'))

      expect(a).not_to equal(b)
    end
  end

  it 'writes through the fixed line format under the per-session path' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'harness.log')
      described_class.build(path).info('one writer')

      line = File.read(path).lines.last
      expect(line).to match(/\[INFO\] one writer/)
    end
  end
end
