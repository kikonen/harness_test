# frozen_string_literal: true

require 'spec_helper'
require 'ui/palette'

RSpec.describe UI::Palette do
  describe '.fetch' do
    it 'defaults to the colored default palette when no name is given' do
      expect(described_class.fetch(nil).name).to eq('default')
      expect(described_class.fetch('').name).to eq('default')
      expect(described_class.fetch('  ').name).to eq('default')
    end

    it 'accepts a configured name' do
      expect(described_class.fetch('basic16').name).to eq('basic16')
      expect(described_class.fetch('none').name).to eq('none')
    end

    it 'raises for an unknown name instead of silently rendering plain' do
      expect { described_class.fetch('crayola') }
        .to raise_error(HarnessError, /unknown output palette "crayola"/)
    end

    it 'names every palette it offers' do
      expect(described_class.names).to eq(%w[default basic16 none])
    end
  end

  describe '.validate!' do
    it 'returns a known name' do
      expect(described_class.validate!(:default)).to eq('default')
    end

    it 'lists what is available when the name is wrong' do
      expect { described_class.validate!('x') }
        .to raise_error(HarnessError, /available: default, basic16, none/)
    end
  end

  describe '#paint' do
    let(:palette) { described_class.new('default') }

    it 'wraps the whole line and resets it' do
      expect(palette.paint(:plan, 'read the tool')).to eq("\e[34mread the tool\e[0m")
    end

    it 'paints the recessive roles with the measured dark gray (SGR 90 is unreadable here)' do
      expect(palette.color_for(:marker)).to eq('38;5;240')
      expect(palette.color_for(:rule)).to eq('38;5;240')
      expect(palette.color_for(:stats)).to eq('38;5;240')
      expect(palette.color_for(:system)).to eq('38;5;240')
    end

    it 'paints warn and compact with the readable brown, not yellow' do
      expect(palette.color_for(:warn)).to eq('38;5;130')
      expect(palette.color_for(:compact)).to eq('38;5;130')
    end

    it "leaves the model answer and tool lines in the terminal's own color" do
      expect(palette.paint(:response, 'done')).to eq('done')
      expect(palette.paint(:text, '  [file.write] ok')).to eq('  [file.write] ok')
    end

    it 'paints only roles the palette names - an unknown type is left plain' do
      expect(palette.paint(:brand_new_kind, 'text')).to eq('text')
    end

    it 'paints nothing in the none palette' do
      none = described_class.new('none')
      expect(none.paint(:plan, 'read the tool')).to eq('read the tool')
      expect(none.color_for(:plan)).to be_nil
    end

    it 'uses no extended-ramp color in basic16' do
      basic = described_class.new('basic16')
      colors = described_class::PALETTES['basic16'].values.compact

      expect(colors).to all(match(/\A3[0-7]\z/))
      expect(basic.color_for(:warn)).to eq('33')
    end

    it 'never uses a background color or the bright 90-97 band (unreadable on a light background)' do
      colors = described_class::PALETTES.values.flat_map(&:values).compact

      expect(colors).not_to include(a_string_matching(/\A4[0-7]\z/))
      expect(colors).not_to include(a_string_matching(/\A9[0-7]\z/))
      expect(colors).not_to include(a_string_matching(/\A37\z/))
    end
  end

  describe '#initialize' do
    it 'rejects an unknown palette name' do
      expect { described_class.new('nope') }.to raise_error(HarnessError, /unknown palette/)
    end
  end
end
