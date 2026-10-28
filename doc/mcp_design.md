# MCP client support (issue #48)

The harness is an MCP **client**: it connects to external Model Context Protocol
servers over stdio and exposes their tools to the model as ordinary harness
tools. Phase 1 is **tools-only** (`tools/list` + `tools/call`); resources,
prompts, and sampling are deferred.

## Scope and boundaries

- **Client only.** The harness calls servers; it is not itself an MCP server.
- **stdio transport only.** A server is a subprocess the harness spawns and
  handshakes with. HTTP/SSE transports are out of scope for phase 1.
- **Tools only.** `tools/list` builds the tool set; `tools/call` runs one.
- **Opt-in.** With no `mcp_servers:` in the config, no MCP code runs at all:
  `Harness#load_mcp_tools` returns before `require "mcp"`, so the gem is never
  loaded and a run without MCP servers pays nothing for the feature.

## Gem

The official `mcp` Ruby SDK (`gem 'mcp', '~> 1.8'`). It requires `base64`, which
stopped being a default gem in Ruby 3.4, so `base64` is declared in the Gemfile
too - without it `require "mcp"` raises LoadError under bundler.

## Config

`mcp_servers:` is a list of stdio servers (config-only; there is no CLI flag - a
server is a declared, persistent setup, not a one-run toggle):

```yaml
mcp_servers:
  - name: filesystem          # tool namespace: its tools become "<name>.<tool>"
    command: npx              # program to spawn (required)
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"]
    env: { KEY: value }       # optional extra environment for the server
```

`HarnessConfig#normalize_mcp_servers` requires a `name` and a `command` per entry
(an entry missing either is a config error, not a silently skipped server - a
server the user typed but that quietly did not load would read as "my tools are
there" when they are not). `args` defaults to `[]`, `env` to `{}`; both are
stringified (an env value must be a string when it reaches the subprocess spawn).

## Wiring

- `Mcp::ServerConnection` (`lib/mcp/server_connection.rb`) owns one server: the
  subprocess spawned by the gem's stdio transport, the initialize handshake, the
  tool list, and the `tools/call` round-trip. It does NOT `require "mcp"` itself;
  the `::MCP::` constants resolve at call time, after Harness required the gem.
- `Mcp::ToolAdapter` (`lib/mcp/tool_adapter.rb`) is a `Tool` that forwards to one
  tool on a server. It is registered as `"<server>.<tool>"` so each server is its
  own namespace, and its OpenAI `parameters` are the MCP `inputSchema` (already a
  JSON-Schema object, so it maps directly; the JSON-Schema bookkeeping such as
  `$schema`/`type` is dropped).
- `Harness#load_mcp_tools` (called from `build_tool_registry`) requires the gem
  lazily, connects each server, and registers each tool. A tool whose name
  collides with a built-in is skipped (the built-in wins) and reported. A server
  that fails to start degrades to a status note rather than crashing the run.
- `Harness#mcp_status_notes` records what startup had to report (a connected
  server's tool count, a failed start, a name collision). The CLI prints each in
  the startup banner, so a run never silently pretends its MCP tools are
  available.
- `Harness#close_mcp` closes every subprocess this run spawned. The CLI calls it
  on shutdown and on a mid-run `/resume` rebuild (the run being replaced owns its
  own servers).

## Consent

An MCP tool runs like a built-in tool - **no per-call dialog** - because the USER
declared the server in the config. The server is the trust boundary the user
chose. An MCP call is not a shell command, so the `run.command` disaster
denylist does not apply to the call itself; nothing here weakens that denylist.

## Error handling

A server-returned error (which the gem raises as `MCP::Client::ServerError`) and
any transport failure both become an `"error: ..."` string out of
`ServerConnection#call_tool` - never a raise out of `execute`, so one bad server
cannot break the turn. `content_to_text` flattens a `tools/call` result: text
blocks are joined, an image block is named (base64 in the chain is huge and
useless to the model), a resource block is inlined or named by uri, an unknown
block is compacted to JSON, and `isError` answers with the server's own text.

## What MCP tools never touch

MCP tools go into `tools_payload` (the tool definitions sent with every request).
They are **never** written into `config/system_prompt.txt`.
