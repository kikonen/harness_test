# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'image_delivery'

# A store double that never touches disk: these specs decide FATES, and
# ImageStore's own specs cover the writing. mime_type/bytes are part of the
# real save signature the delivery calls, so the double accepts them unused.
class FakeStore
  attr_reader :saved

  def initialize(writeable: true)
    @saved     = []
    @writeable = writeable
  end

  def save(server:, tool:, mime_type:, **_rest)
    return nil unless @writeable

    name = "#{server}_#{tool}_#{@saved.size + 1}.#{mime_type.to_s.split('/').last}"
    @saved << name
    ".harness/content/#{name}"
  end

  def harness_state?(path)
    path.to_s.start_with?('.harness/')
  end
end

RSpec.describe ImageDelivery do
  def image(bytes: 'x' * 3000, mime: 'image/png', server: 'blender', tool: 'shot')
    ToolResult::Image.new(server: server, tool: tool, mime_type: mime,
                          bytes: bytes.b)
  end

  def delivery(vision: true, store: FakeStore.new, bytes: 10_000,
               count: 4, tokens: 40_000)
    ImageDelivery.new(vision: vision, store: store,
                      max_inline_bytes: bytes, max_inline_images: count,
                      max_inline_tokens: tokens)
  end

  def plan_for(delivery, images)
    delivery.plan(ToolResult.new(text: 'shot', images: images))
  end

  describe 'inline decisions' do
    it 'inlines one small image for a vision profile' do
      decisions = plan_for(delivery, image(bytes: 'x' * 100))

      expect(decisions.map(&:mode)).to eq([:inline])
    end

    it 'inlines nothing for a profile that does not declare vision' do
      decisions = plan_for(delivery(vision: false), image(bytes: 'x' * 100))

      expect(decisions.map(&:mode)).to eq([:file])
      expect(decisions.first.reason).to include("no vision: the active profile does not declare it")
    end

    it 'treats a missing vision flag as no image support' do
      d = ImageDelivery.new(vision: nil, store: FakeStore.new, max_inline_bytes: 10_000,
                            max_inline_images: 4, max_inline_tokens: 40_000)

      expect(d.vision?).to be(false)
      expect(plan_for(d, image).first.mode).to eq(:file)
    end

    it 'refuses a single image over the byte cap' do
      decisions = plan_for(delivery(bytes: 1000), image(bytes: 'x' * 1001))

      expect(decisions.first.mode).to eq(:file)
      expect(decisions.first.reason).to include('over the 1000-byte inline cap')
    end

    it 'refuses more images than the per-result limit but keeps the rest' do
      decisions = plan_for(
        delivery(count: 2),
        [image(bytes: 'x' * 10), image(bytes: 'x' * 10), image(bytes: 'x' * 10)])

      expect(decisions.map(&:mode)).to eq(%i[inline inline file])
      expect(decisions.last.reason).to include('over the 2-image limit per result')
    end
  end

  describe 'the inline budget is TURN-scoped, not per-result' do
    it 'stops inlining once the turn budget is spent, across separate results' do
      # 3000 bytes -> 4000 base64 chars -> 1000 estimated tokens; a 2500-token
      # budget therefore affords exactly two images for the whole turn.
      d = delivery(tokens: 2500, bytes: 100_000)

      first  = plan_for(d, image(bytes: 'x' * 3000))
      second = plan_for(d, image(bytes: 'x' * 3000))
      third  = plan_for(d, image(bytes: 'x' * 3000))

      expect(first.map(&:mode)).to eq([:inline])
      expect(second.map(&:mode)).to eq([:inline])
      expect(third.map(&:mode)).to eq([:file])
      expect(third.first.reason).to include('token inline budget')
    end

    it 'does not let several images of ONE result jointly exceed the budget' do
      d = delivery(tokens: 1500, bytes: 100_000)

      decisions = plan_for(d, [image(bytes: 'x' * 3000), image(bytes: 'x' * 3000)])

      expect(decisions.map(&:mode)).to eq(%i[inline file])
    end

    it 'resets the per-result image count for the next result' do
      d = delivery(count: 1, tokens: 100_000, bytes: 100_000)

      expect(plan_for(d, image(bytes: 'x' * 10)).first.mode).to eq(:inline)
      expect(plan_for(d, image(bytes: 'x' * 10)).first.mode).to eq(:inline)
    end
  end

  describe 'every image is spilled when the model may not see it' do
    it 'names the stored path so the text alone is actionable' do
      store = FakeStore.new
      decisions = plan_for(delivery(vision: false, store: store), image)

      expect(decisions.first.path).to eq('.harness/content/blender_shot_1.png')
      expect(store.saved).to eq(['blender_shot_1.png'])
    end

    it 'still names the path when an image IS inlined (the durable reference)' do
      decisions = plan_for(delivery, image)

      expect(decisions.first.mode).to eq(:inline)
      expect(decisions.first.path).to eq('.harness/content/blender_shot_1.png')
    end

    it 'drops the image only when the store write itself failed' do
      decisions = plan_for(delivery(vision: false, store: FakeStore.new(writeable: false)),
                           image)

      expect(decisions.first.mode).to eq(:drop)
      expect(decisions.first.reason).to include("no vision: the active profile does not declare it")
    end

    it 'still inlines for a vision profile when the store is unavailable (no durable path)' do
      decisions = plan_for(delivery(store: nil), image)

      expect(decisions.first.mode).to eq(:inline)
      expect(decisions.first.path).to be_nil
    end

    it 'drops when there is neither a vision profile nor a store' do
      decisions = plan_for(delivery(vision: false, store: nil), image)

      expect(decisions.first.mode).to eq(:drop)
      expect(decisions.first.path).to be_nil
    end
  end

  describe '#describe (the text the model reads)' do
    it 'names the fate, the size, and where the bytes are' do
      d    = delivery(vision: false)
      text = d.describe(plan_for(d, image(bytes: 'x' * 1234)))

      expect(text).to eq('[image: image/png, 1234 bytes stored as ' \
                         '.harness/content/blender_shot_1.png ' \
                         '(harness state - reach it with the shell, not the file tools) ' \
                         '- no vision: the active profile does not declare it]')
    end

    it 'never claims an image was attached when it was not' do
      d = delivery(vision: false)

      expect(d.describe(plan_for(d, image))).not_to include('attached')
    end

    it 'says the blob store write failed too when nothing could be done' do
      d = delivery(vision: false, store: FakeStore.new(writeable: false))
      text = d.describe(plan_for(d, image))

      expect(text).to include('dropped:', 'the blob store write failed too')
    end

    it 'one line per image' do
      d = delivery(count: 1)
      decisions = plan_for(d, [image(bytes: 'x' * 10), image(bytes: 'x' * 10)])

      expect(d.describe(decisions).lines.size).to eq(2)
    end
  end

  describe '#inlineable? / #inlined?' do
    it 'returns only the inlined decisions, in order' do
      d = delivery(count: 1)
      decisions = plan_for(d, [image(bytes: 'x' * 10), image(bytes: 'x' * 10)])

      expect(d.inlineable?(decisions).size).to eq(1)
      expect(d.inlined?(decisions)).to be(true)
    end

    it 'reports nothing inlined for a text profile' do
      d = delivery(vision: false)

      expect(d.inlineable?(plan_for(d, image))).to eq([])
      expect(d.inlined?(plan_for(d, image))).to be(false)
    end
  end

  describe '.base64_of' do
    it 'encodes the bytes in the compact (unbroken) form' do
      decision = plan_for(delivery, image(bytes: 'hi'.b)).first

      expect(described_class.base64_of(decision)).to eq('aGk=')
      expect(described_class.base64_of(decision)).not_to include("\n")
    end
  end

  describe '#estimated_tokens' do
    it 'estimates from the BASE64 length, not the decoded size' do
      d = delivery
      # 3000 bytes -> 4000 base64 chars -> 1000 tokens at 4 chars/token.
      expect(d.estimated_tokens(image(bytes: 'x' * 3000))).to eq(1000)
    end
  end
end
