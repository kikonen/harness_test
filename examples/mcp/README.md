# MCP example (issue #48)

A minimal, runnable Model Context Protocol round-trip in Ruby, using the
official `mcp` gem. It shows both halves: a **server** that exposes one tool and
a **client** that spawns it, lists its tools, and calls one.

## Files

- `echo_server.rb` - a stdio MCP server exposing one tool, `echo_tool`.
- `echo_client.rb` - a stdio MCP client that spawns the server, handshakes,
  lists tools, calls `echo_tool`, and closes the connection.

## Run it

From the repo root (the `mcp` gem is bundled there):

```
bundle exec ruby examples/mcp/echo_client.rb
```

Expected output:

```
tool: echo_tool - Echoes back its message argument
result: echo: hello
```

The client spawns the server as a subprocess, so you do not run
`echo_server.rb` yourself. Running it directly just makes it wait on stdin (it
speaks JSON-RPC over stdio).

## Plug it into the harness

The harness is an MCP *client* (issue #48). Declare the server in your config
(`.harness/config.yml`, or the user-home config) and its tools appear to the
model namespaced as `<name>.<tool>` - here `echo.echo_tool`:

```yaml
mcp_servers:
  - name: echo
    command: ruby
    args: ["examples/mcp/echo_server.rb"]
```

- Config-only: there is no CLI flag - a server is a persistent setup, not a
  one-run toggle.
- Opt-in: omit `mcp_servers:` entirely and no MCP code runs (the gem is not even
  loaded).
- A server that fails to start prints `[mcp] ...` in the startup banner and the
  run continues without it.

## Notes

- The tool name is the **class-derived** name (`echo_tool`), not the Ruby class
  name (`EchoTool`).
- `call_tool` returns the full JSON-RPC envelope; the text content is at
  `result["result"]["content"][0]["text"]`.
- A server-side error raises `MCP::Client::ServerError`, so wrap `call_tool` in
  a `rescue` (the harness adapter does this and maps it to an `"error: ..."`
  string).
- On Ruby >= 3.4 the `mcp` gem needs `base64`, which is no longer a default gem;
  the repo's Gemfile declares it.

Rationale and full design: `doc/mcp_design.md`.
