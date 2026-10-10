# frozen_string_literal: true

require 'ui/editor'
require 'stringio'

RSpec.describe UI::Editor do
  def result_text(r) = r.text
  def result_status(r) = r.status

  describe '#read on a non-tty stream (dumb path)' do
    it 'returns :submitted for a real line' do
      ed = described_class.new(StringIO.new("steer left\n"))
      r = ed.read
      expect(result_status(r)).to eq(:submitted)
      expect(result_text(r)).to eq('steer left')
    end

    it 'returns :empty for a blank line (bare Enter = no action, T3 design)' do
      ed = described_class.new(StringIO.new("\n"))
      expect(result_status(ed.read)).to eq(:empty)

      ed2 = described_class.new(StringIO.new("   \n"))
      expect(result_status(ed2.read)).to eq(:empty)
    end

    it 'returns :eof when the stream is exhausted' do
      ed = described_class.new(StringIO.new)
      expect(result_status(ed.read)).to eq(:eof)
    end

    it 'ignores the prefill on the dumb path (Reline-only feature)' do
      ed = described_class.new(StringIO.new("real line\n"))
      r = ed.read(prefill: 'old draft')
      expect(result_text(r)).to eq('real line')
    end

    it 'ignores a custom prompt on the dumb path (no prompt is printed)' do
      ed = described_class.new(StringIO.new("ok\n"))
      r = ed.read(prompt: '> ')
      expect(result_status(r)).to eq(:submitted)
      expect(result_text(r)).to eq('ok')
    end
  end

  describe 'streams without tty? (pipes)' do
    it 'takes the dumb path (pipes have no tty? method behavior we rely on)' do
      reader, writer = IO.pipe
      begin
        ed = described_class.new(reader)
        expect(ed.send(:tty?)).to be(false)

        writer.puts 'note from a pipe'
        r = ed.read
        expect(result_status(r)).to eq(:submitted)
        expect(result_text(r)).to eq('note from a pipe')
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
      end
    end
  end

  describe 'install_esc! (idempotent global Reline patch)' do
    it 'installs the LineEditor module only once' do
      expect { described_class.install_esc! }
        .to change { Reline::LineEditor.ancestors.include?(UI::Editor::RelineEscCancel) }
        .from(false).to(true)

      before = Reline::LineEditor.ancestors.count
      described_class.install_esc!
      expect(Reline::LineEditor.ancestors.count).to eq(before)
    end
  end
end
