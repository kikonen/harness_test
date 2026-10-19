# frozen_string_literal: true

require 'spec_helper'
require 'help_topics'

RSpec.describe HelpTopics do
  describe 'the topic set' do
    it 'has a topic for every prose area the old /help dump covered' do
      expect(described_class::TOPICS.keys).to include(
        'access', 'shell', 'consent', 'conversation', 'saving', 'rules', 'input', 'notes', 'keys'
      )
    end

    it 'gives each topic a title and at least one body paragraph' do
      described_class::TOPICS.each_value do |topic|
        expect(topic.title).not_to be_empty
        expect(topic.paragraphs).not_to be_empty
      end
    end

    it 'names the topic by its own key (a page prints "/help <name>" from it)' do
      described_class::TOPICS.each do |name, topic|
        expect(topic.name).to eq(name)
      end
    end

    it 'keeps each paragraph a single wrapped-able string (no hand-aligned lines)' do
      described_class::TOPICS.each_value do |topic|
        topic.paragraphs.each do |paragraph|
          expect(paragraph).not_to include("\n")
        end
      end
    end
  end

  describe '.fetch' do
    it 'finds a topic by name' do
      expect(described_class.fetch('consent').title).to eq('Shell consent postures and the safety check')
    end

    it 'is case-insensitive and tolerates padding' do
      expect(described_class.fetch('  CONSENT ').name).to eq('consent')
    end

    it 'returns nil for a name it does not have' do
      expect(described_class.fetch('nothere')).to be_nil
    end
  end

  describe '.validate!' do
    it 'accepts a registry no topic name collides with' do
      expect { described_class.validate!(%w[help exit tools]) }.not_to raise_error
    end

    it 'refuses a topic name that is also a command name (/help x could mean two things)' do
      colliding = { 'session' => HelpTopics::Topic.new(
        name: 'session', title: 'Both', paragraphs: ['body'], see_also: []
      ) }

      expect { described_class.validate!(%w[help session], topic_set: colliding) }
        .to raise_error(HarnessError, /topic name collides with a command: session/)
    end

    it 'refuses a topic with no body' do
      hollow = { 'hollow' => HelpTopics::Topic.new(
        name: 'hollow', title: 'Empty', paragraphs: [], see_also: []
      ) }

      expect { described_class.validate!(%w[help], topic_set: hollow) }
        .to raise_error(HarnessError, /help topic "hollow" has no body/)
    end
  end
end
