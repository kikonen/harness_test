# frozen_string_literal: true

require_relative "session"

# What happens to a tool-result image (issue #449). ONE place decides, so the
# MCP adapter, Harness and the backends cannot disagree about whether the model
# was given pixels or only a path. doc/mcp_images_design.md.
#
# EVERY image is spilled to the blob store when the write is possible: that is
# the durable reference a saved session can keep, and the form a text model can
# act on. An image is additionally INLINED (base64 into the next request) only
# when the active model profile says it can see images AND the budgets allow
# it. Inlining is a budgeted decision, never a default: base64 costs 4/3 the
# file size in bytes and ~1 token per 4 of them, and a Blender screenshot
# measured 1.6 MB of base64 - four times a 65536-token context window.
#
# ONE OBJECT PER TURN: the token budget is a turn budget. Five screenshots
# across five tool results must not jointly smuggle 200K tokens into a 65K
# window just because each result looked affordable on its own.
class ImageDelivery
  Decision = Struct.new(:image, :mode, :reason, :path, keyword_init: true) do
    def inline?
      mode == :inline
    end
  end

  attr_reader :max_inline_bytes, :max_inline_images, :max_inline_tokens

  def initialize(vision:, store:, max_inline_bytes:, max_inline_images:,
                 max_inline_tokens:)
    @vision            = vision == true
    @store             = store
    @max_inline_bytes  = max_inline_bytes.to_i
    @max_inline_images = max_inline_images.to_i
    @max_inline_tokens = max_inline_tokens.to_i
    @turn_tokens       = 0
  end

  def vision?
    @vision
  end

  # Decide every image of ONE tool result, spending this turn's remaining
  # inline budget. The per-result image count resets each call; the token
  # budget does not.
  def plan(result)
    inlined_for_result = 0
    result.images.map do |image|
      decision = decide(image, inlined_for_result)
      next decision unless decision.inline?

      @turn_tokens += estimated_tokens(image)
      inlined_for_result += 1
      decision
    end
  end

  def estimated_tokens(image)
    (image.base64_size / Session::EST_CHARS_PER_TOKEN).ceil
  end

  def inlineable?(decisions)
    decisions.select(&:inline?)
  end

  def inlined?(decisions)
    decisions.any?(&:inline?)
  end

  # The text a tool result gets in the chain when it carried images: one line
  # per image naming its fate. Never a bare "[image: ...]" - the model must be
  # able to tell "the server is broken" from "this model cannot see images",
  # and must be told where the bytes are when it cannot see them.
  def describe(decisions)
    decisions.filter_map { |d| describe_one(d) }.join("\n")
  end

  # The base64 a vision request needs, for inlined images only.
  def self.base64_of(decision)
    [decision.image.bytes.to_s].pack("m0")
  end

  private

  def decide(image, inlined_for_result)
    reason = inline_block_reason(image, inlined_for_result)
    path   = spill_path(image)

    if reason.nil?
      Decision.new(image:, mode: :inline, reason: nil, path:)
    elsif path
      Decision.new(image:, mode: :file, reason:, path:)
    else
      Decision.new(image:, mode: :drop, reason:, path: nil)
    end
  end

  # nil = every budget is met, so this image may be inlined. The reason a
  # spill cites is text the model reads, so it must name WHICH budget.
  def inline_block_reason(image, inlined_for_result)
    return "no vision: the active profile does not declare it" unless vision?
    return over_image_limit_reason if inlined_for_result >= max_inline_images
    return over_token_budget_reason if over_token_budget?(image)
    return "over the #{max_inline_bytes}-byte inline cap" if over_byte_cap?(image)

    nil
  end

  def over_byte_cap?(image)
    image.byte_size > max_inline_bytes
  end

  def over_image_limit_reason
    "over the #{max_inline_images}-image limit per result"
  end

  def over_token_budget?(image)
    @turn_tokens + estimated_tokens(image) > max_inline_tokens
  end

  def over_token_budget_reason
    "over the #{max_inline_tokens}-token inline budget"
  end

  def spill_path(image)
    # A disk image already has a path the model can open (issue #451): naming a
    # copy under .harness/ would duplicate bytes the model could read directly,
    # so the reference IS the answer. A downloaded file has no original path, so
    # it is spilled, but named for the artifact (save_named) rather than the MCP
    # <server>_<tool>_<n> shape. Otherwise the MCP path stands.
    return image.reference.to_s if image.reference

    return nil if @store.nil?
    if image.name_hint
      return @store.save_named(
        name: image.name_hint, mime_type: image.mime_type, bytes: image.bytes)
    end

    @store.save(
      server: image.server,
      tool: image.tool,
      mime_type: image.mime_type,
      bytes: image.bytes)
  end

  def describe_one(decision)
    image = decision.image
    head  = "[image: #{image.mime_type}, #{image.byte_size} bytes"
    where = location_note(decision)

    case decision.mode
    when :inline then "#{head} attached to this result#{where}]"
    when :file   then "#{head}#{where} - #{decision.reason}]"
    else "#{head} dropped: #{decision.reason}#{store_note}]"
    end
  end

  # Where the bytes live, in words the model can act on. A disk reference is the
  # file the model already has (issue #451), so it says "at", not "stored as";
  # a spilled blob names the store and whether the file tools can open it.
  def location_note(decision)
    return "" unless decision.path
    return " at #{decision.path}" if decision.image.reference

    " stored as #{decision.path}#{state_note(decision.path)}"
  end

  # The model must be told where the bytes are AND that the file tools will not
  # open them: a silent denial on .harness/ reads as a harness bug.
  def state_note(path)
    return "" unless @store&.harness_state?(path)

    " (harness state - reach it with the shell, not the file tools)"
  end

  def store_note
    @store.nil? ? "" : " (the blob store write failed too)"
  end
end
