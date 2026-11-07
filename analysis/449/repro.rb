# frozen_string_literal: true

# Issue #449: an MCP image content block reached the model as a bare label with
# no pixels. Run from the repo root: ruby analysis/449/repro.rb
#
# The defect is reproducible from the WIRE HASH alone - content_to_result is a
# class method and needs no server, no transport and no MCP gem (the ::MCP::
# constants resolve only inside #connect/#call_tool).
#
# BEFORE (master): content_to_text collapsed every image block to a label and
# never read the "data" key, so the base64 was decoded by nothing and thrown
# away. It also read the wire spelling "mimeType" while mcp 1.8.2 hands the
# client the gem's keyword spelling "mime_type" - so even the mime type was
# lost, and a server that DID name its type reported "[image: unknown]".
#
# AFTER: content_to_result returns a ToolResult carrying the decoded bytes when
# the result had images, a plain String when it did not, and names a block
# whose data will not decode instead of spilling it as a broken file.
require "tmpdir"

require_relative "../../lib/mcp/server_connection"
require_relative "../../lib/tool_result"
require_relative "../../lib/image_store"

# A 1x1 transparent PNG: the base64 a real server puts in a block's "data".
PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk" \
  "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

# mime_key is the point of section 2: the same block spelled both ways.
def image_block(mime_key: "mime_type", mime: "image/png", data: PNG_B64)
  { "type" => "image", mime_key => mime, "data" => data }
end

def text_block(text)
  { "type" => "text", "text" => text }
end

def call(content, tool_name: "get_screenshot_of_area_as_image", error: false)
  result = { "content" => Array(content) }
  result["isError"] = true if error
  Mcp::ServerConnection.content_to_result(
    { "result" => result },
    server_name: "blender",
    tool_name:)
end

puts "== 1. a text-only result still returns a plain String =="
plain = call([text_block("ok")])
puts "  class   : #{plain.class}"
puts "  content : #{plain.inspect}"

puts "\n== 2. the #449 symptom: an image block, both mime spellings =="
[
  ["mimeType", "wire spelling"],
  ["mime_type", "gem keyword spelling"]
].each do |key, label|
  out = call([text_block("done"), image_block(mime_key: key)])
  puts "  #{label.ljust(22)} -> #{out.class}, images=#{out.images.size}, " \
    "mime=#{out.images.first&.mime_type.inspect}, bytes=#{out.images.first&.byte_size}"
end

puts "\n== 3. the bytes survive intact (a byte container, not text) =="
img = call([image_block])
bytes = img.images.first.bytes
puts "  encoding : #{bytes.encoding}"
puts "  PNG magic: #{bytes[0, 4].unpack('H*').first} (89504e47 = \\x89PNG)"
puts "  tool text: #{img.text.inspect} - carries no image note yet"
puts "  summary  : #{img.summary}"

puts "\n== 4. corrupt base64 is NAMED, not spilled as a plausible broken file =="
# unpack("m") IGNORES characters outside the base64 alphabet, so without the
# shape check corrupt data decodes to bytes that look like a broken image.
corrupt = call([image_block(data: "not base64!! ((")])
puts "  class   : #{corrupt.class}"
puts "  content : #{corrupt.to_s.inspect}"

puts "\n== 5. an empty or missing data key is not an image either =="
[
  image_block(data: ""),
  image_block(data: nil)
].each do |block|
  out = call([block])
  puts "  data=#{block["data"].inspect.ljust(6)} -> #{out.class}: #{out.to_s.inspect}"
end

puts "\n== 6. server-side error text still wins over an image block =="
err = call([text_block("no camera"), image_block], tool_name: "render", error: true)
puts "  #{err.class}: #{err.inspect}"

puts "\n== 7. the ToolResult text never carries base64 =="
# Harness#tool_result_message branches on the VALUE, not the origin, so a
# built-in tool returning a ToolResult is already on the image path (#451).
# ImageDelivery appends the fate line later, once per turn.
both = call([text_block("screenshot taken"), image_block])
puts "  chain text: #{both.to_s.inspect} (#{both.to_s.bytesize} bytes, no base64)"
puts "  images beside it: #{both.images.size}"

puts "\n== 8. what is NOT solved: a source with no server: (issue #451) =="
Dir.mktmpdir do |dir|
  store = ImageStore.new(dir)
  [
    ["MCP-shaped (both parts)", { server: "blender", tool: "get_screenshot_of_area" }],
    ["disk-shaped (no server)", { server: nil, tool: "car_thumb.png" }],
    ["disk-shaped (neither)",   { server: nil, tool: nil }],
    ["hostile tool name",       { server: nil, tool: "../../evil" }]
  ].each do |label, parts|
    saved = store.save(**parts, mime_type: "image/png", bytes:)
    puts "  #{label.ljust(24)} -> #{saved}"
  end
  # store.dir is deliberately RELATIVE (it is what the model is told), so the
  # check starts from the temp workdir: globbing store.dir alone would scan
  # the repo's own .harness/ instead of this temp dir.
  store_root = File.join(dir, store.dir)
  in_store = Dir.children(store_root).sort
  # FNM_DOTMATCH because a plain glob will not descend into a leading-dot dir.
  files = Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select do |p|
    File.file?(p)
  end
  inside = File.expand_path(store_root)
  outside = files.reject { |p| File.expand_path(p).start_with?(inside) }
  puts "  blobs in the store (#{in_store.size}): #{in_store.inspect}"
  puts "  none written outside it: #{outside.empty?} (#{files.size} file(s) total)"
end
