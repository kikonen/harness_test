# frozen_string_literal: true

require 'spec_helper'
require 'ui/renderer'

# A concrete subclass stands in for the abstract base: Tool#execute raises, so
# the status API is exercised through an instance the way a real tool uses it.
class ProbeTool < Tool
  def initialize
    super(name: 'probe.run', description: 'probe tool',
          parameters: { type: 'object', properties: {} })
  end

  def execute(args)
    args
  end
end

RSpec.describe Tool do
  describe '.denial_error' do
    it 'returns the plain message when there is no result' do
      expect(described_class.denial_error("error: access denied for 'x'"))
        .to eq("error: access denied for 'x'")
    end

    it 'returns the plain message for a denial without a note' do
      result = { status: :denied, note: nil }
      expect(described_class.denial_error("error: access denied for 'x'", result))
        .to eq("error: access denied for 'x'")
    end

    it 'appends the user\'s note when present' do
      result = { status: :denied, note: 'no, and because X' }
      expect(described_class.denial_error("error: access denied for 'x'", result))
        .to eq("error: access denied for 'x' (user's note: \"no, and because X\")")
    end

    it 'is safe for legacy :denied symbols' do
      expect(described_class.denial_error("error: access denied for 'x'", :denied))
        .to eq("error: access denied for 'x'")
    end

    it 'ignores non-denial results' do
      expect(described_class.denial_error('error: x', :granted))
        .to eq('error: x')
    end
  end

  describe '.granted?' do
    it 'is true only for :granted' do
      expect(described_class.granted?(:granted)).to be(true)
      expect(described_class.granted?({ status: :denied, note: nil })).to be(false)
      expect(described_class.granted?(:blocked)).to be(false)
    end
  end

  describe '.status_type' do
    it 'maps every verdict to its renderer type' do
      expect(described_class.status_type(:ok)).to eq(:status_ok)
      expect(described_class.status_type(:fail)).to eq(:status_fail)
      expect(described_class.status_type(:info)).to eq(:status_info)
    end

    it 'raises on an unknown verdict, naming the available ones' do
      expect { described_class.status_type(:maybe) }
        .to raise_error(ArgumentError, /unknown status verdict :maybe/)
      expect { described_class.status_type(:maybe) }
        .to raise_error(ArgumentError, /available: ok, fail, warn, note, same, info/)
    end

    # A verdict the renderer has no glyph for would print its line followed by
    # " [untyped:...]" - the two maps must stay the same set.
    it 'covers exactly the renderer\'s status types' do
      expect(described_class::STATUS_TYPES.values)
        .to eq(UI::Renderer::STATUS_GLYPHS.keys)
    end
  end

  describe '.push_status' do
    # No Task is active in this example, and the single-thread I/O rule (issue
    # #40) says a status line with nowhere to drain is a no-op rather than a
    # write to a global stream.
    it 'is a no-op when no Task is active' do
      expect(Tool.push_status(label: 'probe', verdict: :ok, message: 'x')).to be_nil
    end

    it 'does not write to $stdout' do
      expect { Tool.push_status(label: 'probe', verdict: :ok, message: 'x') }
        .not_to output.to_stdout
    end
  end

  describe '#status' do
    it 'routes through push_status with the tool\'s own name as the label' do
      tool = ProbeTool.new
      expect(Tool).to receive(:push_status)
        .with(label: 'probe.run', verdict: :ok, message: 'done')
      tool.status(:ok, 'done')
    end
  end

  describe '#namespace and #short_name' do
    it 'splits a dot-notation name' do
      tool = ProbeTool.new
      expect(tool.namespace).to eq('probe')
      expect(tool.short_name).to eq('run')
    end

    it 'treats a dotted name as one namespace when there is no dot' do
      tool = described_class.new(name: 'plain', description: 'd', parameters: {})
      expect(tool.namespace).to eq('plain')
      expect(tool.short_name).to eq('plain')
    end
  end

  describe '#execute' do
    it 'is abstract on the base class' do
      tool = described_class.new(name: 'x.y', description: 'd', parameters: {})
      expect { tool.execute({}) }.to raise_error(NotImplementedError, /Tool#execute not implemented/)
    end
  end

  describe '#to_openai' do
    it 'wraps the tool metadata in the function shape the API expects' do
      tool = ProbeTool.new
      expect(tool.to_openai).to eq(
        { type: 'function',
          function: { name: 'probe.run', description: 'probe tool',
                      parameters: { type: 'object', properties: {} } } }
      )
    end
  end
end
