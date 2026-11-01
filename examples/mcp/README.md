# MCP examples (issue #48 stdio, issue #402 HTTP/SSE)

Minimal, runnable Model Context Protocol round-trips in Ruby, using the official
`mcp` gem. Both transports the harness can reach are covered: a server it
**spawns** (stdio) and a server it **connects to at a URL** (HTTP/SSE).

## This directory has its own bundle

`examples/mcp/Gemfile` is separate from the repo's root Gemfile on purpose: the
HTTP example *serves*, which needs `rack`, and the harness never serves - it is
a client only. So these scripts run from their own bundle:

```
cd examples/mcp
bundle install
```

The stdio pair also works from the repo root (`bundle exec ruby
examples/mcp/echo_client.rb`); the HTTP pair needs the bundle here because of
`rack` and `faraday`.

## Files

| File | What it is |
| --- | --- |
| `echo_server.rb` | stdio MCP server, one tool (`echo_tool`) |
| `echo_client.rb` | stdio MCP client: spawns the server, lists, calls, closes |
| `http_server.rb` | HTTP/SSE MCP server, two tools (`echo_tool`, `server_info_tool`) |
| `http_client.rb` | HTTP/SSE MCP client: connects to a running server at a URL |

## The stdio example

```
cd examples/mcp && bundle exec ruby echo_client.rb
```

Expected output:

```
tool: echo_tool - Echoes back its message argument
result: echo: hello
```

The client spawns the server as a subprocess, so you do not run
`echo_server.rb` yourself. Running it directly just makes it wait on stdin (it
speaks JSON-RPC over stdio).

## The HTTP/SSE example

Start the server in one terminal - it listens on `http://127.0.0.1:4560/mcp`
and requires `Authorization: Bearer example-token`:

```
cd examples/mcp && bundle exec ruby http_server.rb
```

Then talk to it from a second terminal:

```
cd examples/mcp && bundle exec ruby http_client.rb
```

Expected output:

```
connected: http://127.0.0.1:4560/mcp (session: )
tool: echo_tool - Echoes back its message argument
tool: server_info_tool - Reports the server name and how long it has been running
result: echo: hello over HTTP
result: echo_http_server up for 70.0s (streamable HTTP transport)
```

`http_client.rb` is the exact code path the harness takes for an entry with
`url:` instead of `command:`, so it is also a manual check of that branch
without starting the harness. `MCP_URL=... bundle exec ruby http_client.rb`
points it at another URL.

The server is a Rack app: `MCP::Server::Transports::StreamableHTTPTransport` is
one (the gem refuses to load it without `rack`), mounted at `/mcp` behind a
middleware that checks the bearer header. That middleware is not the gem's
OAuth surface (`token_verifier:` / `MCP::Server::OAuth`) - issue #402 wires a
static header only, so the server side is plain Rack.

## Plug them into the harness

The harness is an MCP *client*. Declare a server in your config
(`.harness/config.yml`, or the user-home config) and its tools appear to the
model namespaced as `<name>.<tool>`.

**stdio** (the harness spawns the server):

```yaml
mcp_servers:
  - name: echo
    command: ruby
    args: ["examples/mcp/echo_server.rb"]
```

**HTTP/SSE** (the harness connects to a server already running - start
`http_server.rb` first):

```yaml
mcp_servers:
  - name: echo
    url: http://127.0.0.1:4560/mcp
    headers: { Authorization: "Bearer example-token" }
```

`name` is required, plus exactly one of `command` or `url` - an entry with both
is a config error. The URL is used **as-is**: the harness appends nothing to it,
so the `/mcp` path belongs in the config exactly as `map` sets it in the server.

In the startup banner a connected server reports its tool count and the model
then has `echo.echo_tool` and `echo.server_info_tool`:

```
  [mcp] MCP server 'echo' connected: 2 tool(s)
```

- Config-only: there is no CLI flag - a server is a persistent setup, not a
  one-run toggle.
- Opt-in: omit `mcp_servers:` entirely and no MCP code runs (the gem is not even
  loaded).
- A server that cannot be reached is a banner note, not a crash. Drop the
  `headers:` line above and the server answers 401, which arrives as:

  ```
    [mcp] MCP server 'echo' failed to start (MCP::Client::RequestHandlerError: You are unauthorized to make initialize requests)
  ```

## Notes

- The tool name is the **class-derived** name (`echo_tool`,
  `server_info_tool`), not the Ruby class name (`EchoTool`).
- `call_tool` returns the full JSON-RPC envelope; the text content is at
  `result["result"]["content"][0]["text"]`.
- A server-side error raises `MCP::Client::ServerError`, so wrap `call_tool` in
  a `rescue` (the harness adapter does this and maps it to an `"error: ..."`
  string).
- On Ruby >= 3.4 the `mcp` gem needs `base64`, which is no longer a default gem;
  both Gemfiles declare it.
- The HTTP **client** half needs `faraday`, and the gem does not declare it
  either. Without it `MCP::Client::HTTP#connect` raises `NameError: uninitialized
  constant MCP::Client::HTTP::Faraday` - NOT the gem's own "add faraday to your
  Gemfile" LoadError, because the unresolved constant in its rescue clauses
  fires first (measured on mcp 1.8.2 / ruby 4.0.7). Both Gemfiles declare
  faraday for that reason.
- Closing an HTTP connection ends the session; the server keeps running (unlike
  the stdio close, which terminates the subprocess the client spawned).

Rationale and full design: `doc/mcp_design.md`.
