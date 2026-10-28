# frozen_string_literal: true

# A minimal stdio MCP CLIENT (issue #48 example): it spawns echo_server.rb (next
# to this file) as a subprocess, handshakes, lists its tools, calls one, and
# closes the connection.
#
# Run it from the repo root (the mcp gem is bundled there):
#   bundle exec ruby examples/mcp/echo_client.rb

require "mcp"

server_path = File.expand_path("echo_server.rb", __dir__)

transport = MCP::Client::Stdio.new(
  command: "ruby",
  args: [server_path],
  read_timeout: 30)
client = MCP::Client.new(transport:)

# 1. initialize handshake.
client.connect

# 2. tools/list - the tool name is the class-derived name ("echo_tool").
client.tools.each do |tool|
  puts "tool: #{tool.name} - #{tool.description}"
end

# 3. tools/call - the result is the full JSON-RPC envelope; the text content
#    lives at result["result"]["content"][0]["text"].
result = client.call_tool(name: "echo_tool", arguments: { "message" => "hello" })
puts "result: #{result.dig("result", "content", 0, "text")}"

# 4. shut the server subprocess down.
transport.close
