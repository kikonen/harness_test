# frozen_string_literal: true

require_relative "text_normalizer"

# A tool result that carries IMAGES beside its text (issue #449).
#
# Every tool result in this harness is a String and the message chain is
# text-only, so an image needs a shape that says "here is the text, and here
# are bytes that are NOT text". What happens to those bytes is decided by
# ImageDelivery (doc/mcp_images_design.md); this class only carries them.
#
# INVARIANT: image bytes never enter the message chain, the session JSON or
# TextNormalizer. They are a byte container, not text in some encoding - the
# encoding boundary would mangle them (doc/encoding_design.md).
class ToolResult
  # One image the tool returned. `bytes` is the DECODED payload, BINARY-tagged
  # (a byte container, the same rule as a child-process pipe buffer).
  # server/tool ride along because the spill file is named after where the
  # image came from, and a result may hold images from one call only.
  #
  # Two OPTIONAL fields carry a non-MCP image (issue #451):
  #   reference - a workdir-relative path the model can already reach (a disk
  #     file). When set, ImageDelivery points at the ORIGINAL instead of spilling
  #     a duplicate copy: the bytes the model was given are the file it can open.
  #   name_hint - a real artifact name to spill under (a downloaded file has no
  #     original path, so it is still spilled, but the name should say what it is
  #     rather than the MCP _<server>_<tool>_<n> shape). Ignored when reference is set.
  Image = Struct.new(
    :server,
    :tool,
    :mime_type,
    :bytes,
    :reference,
    :name_hint,
    keyword_init: true) do
    def byte_size
      bytes.to_s.bytesize
    end

    # Base64 emits 4 characters per 3 input bytes, with padding, and THAT
    # number (not the decoded size) is what a request body and a token estimate
    # see. The ~+33% is why an image cannot simply be inlined.
    def base64_size
      4 * (byte_size / 3.0).ceil
    end
  end

  attr_reader :text, :images

  def initialize(text: "", images: [])
    @text   = TextNormalizer.normalize(text)
    # NOT Array(images): Image is a Struct, and Array() on a Struct returns its
    # MEMBERS - a lone image would silently become a list of Strings.
    @images = images.is_a?(Array) ? images : [images].compact
  end

  def images?
    !@images.empty?
  end

  def to_s
    text.to_s
  end

  # What a LOG line may say about a result: sizes only, never the payload.
  # Every tool result is logged, so a megabyte of base64 there is the same
  # mistake as putting it in the chain.
  def summary
    parts = ["text #{text.to_s.length} chars"]
    if images?
      listed = images.map { |i| "#{i.mime_type} #{i.byte_size}B" }.join(", ")
      parts << "#{images.size} image(s): #{listed}"
    end
    parts.join(", ")
  end
end
