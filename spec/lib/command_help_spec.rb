# frozen_string_literal: true

require 'spec_helper'
require 'command_help'

RSpec.describe CommandHelp do
  def build(**overrides)
    described_class.new(**{ usage: 'ctx', summary: 'Show context usage', group: :session }.merge(overrides))
  end

  describe 'construction' do
    it 'defaults forms to the single usage form' do
      expect(build.forms).to eq(['ctx'])
    end

    it 'keeps the declared forms verbatim' do
      help = build(forms: ['param', 'param <key> <value>'])

      expect(help.forms).to eq(['param', 'param <key> <value>'])
    end

    it 'names its group heading from GROUPS' do
      expect(build(group: :access).group_label).to eq('Access and consent')
    end

    it 'refuses an unknown group: help in no group vanishes from the table' do
      expect { build(group: :nonsense) }
        .to raise_error(HarnessError, /unknown help group :nonsense/)
    end

    it 'refuses an empty usage or summary' do
      expect { build(usage: '  ') }.to raise_error(HarnessError, /needs a usage and a summary/)
      expect { build(summary: '') }.to raise_error(HarnessError, /needs a usage and a summary/)
    end
  end

  describe '.suggestions (typo band)' do
    let(:registry) do
      %w[grant clear yolo palette retry session session-clear compact ctx
         reload save resume reasoning sessions tools models model param help exit]
    end

    it 'names the command a one-typo spelling lands on' do
      expect(described_class.suggestions('garnt', registry)).to include('grant')
      expect(described_class.suggestions('palet', registry)).to eq(['palette'])
    end

    it 'treats a prefix as the intended name, not as a typo' do
      expect(described_class.suggestions('res', registry)).to eq(['resume'])
    end

    it 'offers nothing for a name that is simply not close to one' do
      expect(described_class.suggestions('xyzzy', registry)).to eq([])
    end

    it 'caps the list so a bad guess cannot bury the real answer' do
      expect(described_class.suggestions('helo', registry, limit: 1).size).to eq(1)
    end

    it 'is case-insensitive' do
      expect(described_class.suggestions('GRANTT', registry)).to eq(['grant'])
    end
  end

  describe '.edit_distance' do
    it 'counts insertions, deletions and substitutions' do
      expect(described_class.edit_distance('kitten', 'sitting')).to eq(3)
      expect(described_class.edit_distance('', 'abc')).to eq(3)
      expect(described_class.edit_distance('abc', '')).to eq(3)
      expect(described_class.edit_distance('same', 'same')).to eq(0)
    end
  end
end
