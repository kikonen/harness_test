# frozen_string_literal: true

require 'spec_helper'
require 'sensitive_files'

# The NAME half of the sensitive-path guard. Whether a name counts (a scratch
# zone exempts it) is FileList#sensitive? - the only half that knows a working
# directory, which is what the zone test needs.
RSpec.describe SensitiveFiles do
  describe '.sensitive? (the name test)' do
    it 'blocks a .env basename and its variants' do
      expect(described_class.sensitive?('.env')).to be(true)
      expect(described_class.sensitive?('.env.production')).to be(true)
      expect(described_class.sensitive?('config/.env.production')).to be(true)
    end

    it 'blocks a sensitive directory in ANY component of the path' do
      expect(described_class.sensitive?('.git/config')).to be(true)
      expect(described_class.sensitive?('.git/objects/pack/x.idx')).to be(true)
      expect(described_class.sensitive?('vendor/.git/HEAD')).to be(true)
      expect(described_class.sensitive?('.harness/sessions/id/session.json')).to be(true)
      expect(described_class.sensitive?('C:/work/proj/tmp/keep/318/repo/.git/COMMIT_EDITMSG')).to be(true)
    end

    it 'leaves ordinary paths alone' do
      expect(described_class.sensitive?('lib/file_list.rb')).to be(false)
      expect(described_class.sensitive?('tmp/keep/318/issue_crlf.md')).to be(false)
      expect(described_class.sensitive?('tmp/keep/318/repo/README.md')).to be(false)
    end

    it 'is name-only - a zone path is still sensitive HERE (the exemption is FileList\'s)' do
      expect(described_class.sensitive?('tmp/keep/318/repo/.git/config')).to be(true)
    end
  end

  describe '.scratch_zone?' do
    it 'recognises a per-issue zone of either kind' do
      expect(described_class.scratch_zone?('tmp/keep/318/repo/.git/config')).to be(true)
      expect(described_class.scratch_zone?('tmp/scratch/321/probe.rb')).to be(true)
      expect(described_class.scratch_zone?('tmp/keep/318/sub/deep/.git/objects/x')).to be(true)
    end

    it 'accepts a zone name that is not a number' do
      expect(described_class.scratch_zone?('tmp/keep/309-316/i8_drift_and_tail.md')).to be(true)
      expect(described_class.scratch_zone?('tmp/scratch/notes/.git/config')).to be(true)
    end

    it 'requires the <n> segment - the zone list itself is not a zone' do
      expect(described_class.scratch_zone?('tmp/keep/318')).to be(false)
      expect(described_class.scratch_zone?('tmp/keep/.git/config')).to be(false)
      expect(described_class.scratch_zone?('tmp/scratch/.git/config')).to be(false)
    end

    it 'does not match a lookalike directory or the owner zone' do
      expect(described_class.scratch_zone?('tmp/keepz/318/.git/config')).to be(false)
      expect(described_class.scratch_zone?('local/keep/318/.git/config')).to be(false)
      expect(described_class.scratch_zone?('tmp/harness_story/ch01.md')).to be(false)
    end

    it 'is not a zone for a path outside the working directory (no relative form)' do
      expect(described_class.scratch_zone?(nil)).to be(false)
    end
  end
end
