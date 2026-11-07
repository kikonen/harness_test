# frozen_string_literal: true

# Identify an image by its leading bytes (issue #451).
#
# A tool that reads a file (or fetches a URL) needs to know whether the bytes it
# holds are an image BEFORE it decides what to do with them - and the extension
# or the Content-Type is not trustworthy enough to decide on: a PNG renamed .txt
# is still a PNG on disk, and a server can label anything anything. The magic
# number is what the bytes actually are.
#
# A byte container (doc/encoding_design.md): these are comparisons on raw bytes,
# never a text read, so nothing here normalizes or decodes.
module ImageSniffer
  # [magic-bytes, mime_type] pairs, longest signatures first so a JPEG that
  # starts with the shorter FFD8 is matched by its own rule, not a looser one.
  SIGNATURES = [
    ["\x89PNG\r\n\x1A\n".b, "image/png"],
    ["\xFF\xD8\xFF".b,       "image/jpeg"],
    ["GIF87a".b,             "image/gif"],
    ["GIF89a".b,             "image/gif"],
    ["BM".b,                 "image/bmp"],
    ["\x00\x00\x01\x00".b,   "image/x-icon"],
    ["\x1A\x44\x4E\x47".b,   "image/png"]
  ].freeze

  # Content-Type values that mean "this is an image". The leading type before
  # the "/" is the decision, so "image/png" and "image/svg+xml" count and a
  # charset/parameter tail ("image/webp; charset=binary") is cut first.
  def self.image_content?(content_type)
    base = content_type.to_s.downcase.split(";", 2).first.to_s.strip
    base.split("/", 2).first == "image"
  end

  # Returns the mime type the leading bytes identify, or nil when they are not a
  # known image signature.
  def self.sniff(bytes)
    head = bytes.to_s.b
    SIGNATURES.each do |magic, mime|
      return mime if head.start_with?(magic)
    end
    nil
  end

  # True when the bytes look like an image, whatever the name or header claimed.
  def self.image_bytes?(bytes)
    !sniff(bytes).nil?
  end
end
