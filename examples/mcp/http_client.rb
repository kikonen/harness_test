# frozen_string_literal: true

# A minimal HTTP/SSE MCP CLIENT (issue #402 example): it connects to a RUNNING
# http_server.rb (next to this file) at a URL, handshakes, lists its tools,
# calls them, and closes the connection.
#
# It is the exact code path the harness takes for an mcp_servers entry that
# carries `url:` instead of `command:` (lib/mcp/server_connection.rb), so it
# also doubles as a manual check of that branch.
#
# Start the server first, in its own terminal (both live in examples/mcp,
# which has its own Gemfile):
#
#   cd examples/mcp && bundle install
#   bundle exec ruby http_server.rb
#
# then, from a second terminal:
#
#   cd examples/mcp && bundle exec ruby http_client.rb

require "mcp"

URL = ENV.fetch("MCP_URL", "http://127.0.0.1:4560/mcp")
HEADERS = { "Authorization" => "Bearer example-token" }

# The same two keywords the harness passes: url and headers. Note the URL is
# used AS-IS - the harness appends nothing to an mcp_servers url, so the path
# belongs to the config the same way it belongs to the server.
transport = MCP::Client::HTTP.new(url: URL, headers: HEADERS)
client    = MCP::Client.new(transport:)

begin
  # 1. initialize handshake over HTTP (the gem negotiates a session id).
  client.connect
  puts "connected: #{URL} (session: #{transport.session_id})"

  # 2. tools/list - names are class-derived ("echo_tool", "server_info_tool").
  client.tools.each do |tool|
    puts "tool: #{tool.name} - #{tool.description}"
  end

  # 3. tools/call - the result is the full JSON-RPC envelope; the text content
  #    lives at result["result"]["content"][0]["text"].
  result = client.call_tool(
    name: "echo_tool",
    arguments: { "message" => "hello over HTTP" })
  puts "result: #{result.dig("result", "content", 0, "text")}"

  uptime = client.call_tool(name: "server_info_tool", arguments: {})
  puts "result: #{uptime.dig("result", "content", 0, "text")}"
ensure
  # Close the HTTP connection. For a spawned server the close terminates the
  # subprocess; here it ends the session and the remote server keeps running.
  transport.close
end
