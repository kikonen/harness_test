# frozen_string_literal: true

require 'spec_helper'
require 'commands/store_listing'
require 'memories'
require 'tmpdir'
require 'fileutils'

RSpec.describe Commands::StoreListing do
  # The module is the shared SHAPE, not a reader: it takes the store's sorted
  # entries and returns the payload fields, so a pin compares fields to fields.
  subject(:listing) do
    probe = Object.new
    captured = []
    probe.extend(described_class)
    probe.define_singleton_method(:emitted) { captured }
    probe.define_singleton_method(:emit_role) { |type, content| captured << [type, content] }
    probe
  end

  def write_note(dir, name, content)
    FileUtils.mkdir_p(File.join(dir, Memories::DIR))
    File.write(File.join(dir, Memories::DIR, "#{name}.md"), content)
  end

  describe '#listing_rows' do
    it 'numbers the entries in the store sorted order, as fields' do
      Dir.mktmpdir do |dir|
        write_note(dir, 'consent', 'YOLO skips the shell dialog.')
        write_note(dir, 'ci', 'rspec and rubocop on ubuntu.')

        expect(listing.listing_rows(Memories.new(dir).all)).to eq([
          { number: 1, name: 'ci', description: 'rspec and rubocop on ubuntu.', chars: 28 },
          { number: 2, name: 'consent', description: 'YOLO skips the shell dialog.', chars: 28 }
        ])
      end
    end
  end

  describe '#list_index' do
    # The index only wins while IN RANGE, so a store entry genuinely named with
    # digits stays reachable by that name.
    it 'resolves an in-range number to its position in the listing' do
      expect(listing.list_index('2', 3)).to eq(1)
    end

    it 'is nil for an out-of-range number, so the name is tried instead' do
      expect(listing.list_index('3', 2)).to be_nil
    end

    it 'is nil for anything that is not a whole number' do
      expect(listing.list_index('two', 3)).to be_nil
      expect(listing.list_index('0', 3)).to be_nil
    end

    it 'is nil for an empty store' do
      expect(listing.list_index('1', 0)).to be_nil
    end
  end

  describe '#store_rule' do
    it 'shows the number when the entry was asked for by number' do
      expect(listing.store_rule(Memories::DIR, 'consent', 1))
        .to eq("--- 2. consent (#{Memories::DIR}) --------------------------")
    end

    # A name lookup prints no number, and 0 is a legitimate index, so nil is the
    # only value that means "asked by name".
    it 'shows no number for a name lookup' do
      expect(listing.store_rule(Memories::DIR, 'consent', nil))
        .to eq("--- consent (#{Memories::DIR}) -----------------------------")
    end
  end

  describe '#show_body' do
    it 'emits the rule then the body as the :body role' do
      emitted = listing.emitted
      listing.show_body(listing.store_rule(Memories::DIR, 'consent', 1), 'body text')

      expect(emitted).to eq([
        [:rule, "--- 2. consent (#{Memories::DIR}) --------------------------"],
        [:body, 'body text']
      ])
    end

    it 'emits nothing when there is no body to show' do
      listing.show_body('rule', nil)

      expect(listing.emitted).to eq([])
    end
  end
end
