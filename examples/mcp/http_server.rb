# frozen_string_literal: true

# A minimal HTTP/SSE MCP SERVER (issue #402 example): it exposes two tools and
# serves them over the gem's streamable-HTTP transport, which IS a Rack app.
#
# Unlike echo_server.rb this one is NOT spawned by the client - it is a server
# the client (or the harness) connects to at a URL. Start it in its own
# terminal from examples/mcp (that directory has its own Gemfile because only
# the server half needs rack):
#
#   cd examples/mcp && bundle install
#   bundle exec ruby http_server.rb         # listens on http://127.0.0.1:4560/mcp
#
# then talk to it from another terminal:
#
#   cd examples/mcp && bundle exec ruby http_client.rb
#
# or point the harness at it: an mcp_servers entry with `url:` where today's
# would have a `command:` (see README.md).

require "mcp"
require "rack"
require "rackup/handler/webrick"

HOST = "127.0.0.1"
PORT = 4560
# The transport answers whatever is routed to it - the path is the mount point,
# not something the transport inspects. The harness connects to an mcp_servers
# url AS-IS, so this is the URL the config has to name.
PATH = "/mcp"

# The bearer token this example expects. It stands for the header the harness
# config sends from an entry's `headers:` (issue #402).
TOKEN = "example-token"

class EchoTool < MCP::Tool
  description "Echoes back its message argument"
  input_schema(
    properties: {
      message: { type: "string" }
    },
    required: ["message"])

  class << self
    # The gem always passes server_context: (the connection/handshake context);
    # this tool ignores it, so the unused-argument cop is silenced for it.
    # rubocop:disable Lint/UnusedMethodArgument
    def call(message:, server_context:)
      MCP::Tool::Response.new([{ type: "text", text: "echo: #{message}" }])
    end
    # rubocop:enable Lint/UnusedMethodArgument
  end
end

class ServerInfoTool < MCP::Tool
  description "Reports the server name and how long it has been running"
  input_schema(properties: {})

  STARTED = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def self.call
    uptime = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - STARTED).round(1)
    message = "echo_http_server up for #{uptime}s (transport: streamable HTTP)"
    MCP::Tool::Response.new([{ type: "text", text: message }])
  end
end

# A Rack middleware requiring the bearer token: proof that a configured header
# reaches a remote server. Without the header every request answers 401, and
# the harness reports the server as failed to start. This is NOT the gem's
# OAuth surface (`token_verifier:` / MCP::Server::OAuth) - #402 wires a static
# header only, so the server side is an ordinary Rack middleware.
class RequireBearer
  def initialize(app, token:)
    @app   = app
    @token = token
  end

  def call(env)
    provided = env["HTTP_AUTHORIZATION"].to_s
    return @app.call(env) if provided == "Bearer #{@token}"

    [401, { "content-type" => "text/plain" }, ["missing or wrong Authorization header\n"]]
  end
end

server = MCP::Server.new(
  name: "echo_http_server",
  version: "0.1.0",
  tools: [EchoTool, ServerInfoTool])

transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

# The Rack handler mounts its app at "/", so the path the config must name is
# set by `map` here rather than by the transport.
app = Rack::Builder.new do
  use(RequireBearer, token: TOKEN)
  map(PATH) do
    run(transport)
  end
end

puts "MCP HTTP server on http://#{HOST}:#{PORT}#{PATH} (Authorization: Bearer #{TOKEN})"
puts "Ctrl+C to stop."

Rackup::Handler::WEBrick.run(app, BindAddress: HOST, Port: PORT)
