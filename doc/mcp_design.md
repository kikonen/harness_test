# MCP client support (issue #48, HTTP/SSE transport issue #402)

The harness is an MCP **client**: it connects to external Model Context Protocol
servers and exposes their tools to the model as ordinary harness tools. It is
**tools-only** (`tools/list` + `tools/call`); resources, prompts, and sampling
are deferred (issue #403).

## Scope and boundaries

- **Client only.** The harness calls servers; it is not itself an MCP server.
- **Two transports.** A server is either a subprocess the harness spawns and
  handshakes with (stdio) or a remote endpoint it connects to over the gem's
  streamable-HTTP/SSE transport (issue #402). Everything above the transport -
  the handshake, `tools/list`, `tools/call` - is the gem's transport-agnostic
  `Client` API, so only `ServerConnection#connect` branches.
- **Tools only.** `tools/list` builds the tool set; `tools/call` runs one.
- **Opt-in.** With no `mcp_servers:` in the config, no MCP code runs at all:
  `Harness#load_mcp_tools` returns before `require "mcp"`, so the gem is never
  loaded and a run without MCP servers pays nothing for the feature.
- **No OAuth wiring.** The gem ships `MCP::Client::OAuth`; a url entry passes
  `url:` and `headers:` only. Static headers (an `Authorization` value the user
  wrote in the config) are the whole authentication surface today.

## Gem

The official `mcp` Ruby SDK (`gem 'mcp', '~> 1.8'`). It requires `base64`, which
stopped being a default gem in Ruby 3.4, so `base64` is declared in the Gemfile
too - without it `require "mcp"` raises LoadError under bundler.

Its **HTTP** client transport (`MCP::Client::HTTP`, issue #402) requires
`faraday` the same lazy way (`#require_faraday!`) and does not declare it as a
dependency, so `faraday` is in the Gemfile too. Without it a `url:` entry fails
at connect - and NOT with the gem's own "add faraday to your Gemfile" LoadError:
the NameError for the unresolved `Faraday` constant in the transport's rescue
clauses fires first, which is what the failure looks like in the banner
(measured on mcp 1.8.2 / ruby 4.0.7). Only the HTTP half pays for it - a stdio
setup never loads faraday.

Runnable examples of both transports: `examples/mcp/` (its own bundle - its
HTTP example serves too, which needs `rack`, and the harness never serves).

## Config

`mcp_servers:` is a list of servers (config-only; there is no CLI flag - a
server is a declared, persistent setup, not a one-run toggle). Each entry names
ONE server and says how to reach it:

```yaml
mcp_servers:
  - name: filesystem          # tool namespace: its tools become "<name>.<tool>"
    command: npx              # program to spawn (required)
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"]
    env: { KEY: value }       # optional extra environment for the server
  - name: remote              # HTTP/SSE transport instead of a subprocess
    url: https://example.com/mcp
    headers: { Authorization: "Bearer ..." }   # optional request headers
```

`HarnessConfig#normalize_mcp_servers` requires a `name` and **exactly one of
`command` or `url`** per entry (an entry missing them, or carrying both, is a
config error rather than a silently degraded server - a server the user typed
but that quietly did not load would read as "my tools are there" when they are
not, and a both-transport entry would make the harness guess which one was
meant). A `url` must start with `http://` or `https://`: any other scheme would
fail deep inside `connect` and surface as a broken server rather than as bad
config. `args` defaults to `[]`, `env` and `headers` to `{}`; all are stringified
(an env value must be a string when it reaches the subprocess spawn, a header
value when it reaches the HTTP request).

## Wiring

- `Mcp::ServerConnection` (`lib/mcp/server_connection.rb`) owns one server: the
  transport (`MCP::Client::Stdio` for a command entry, `MCP::Client::HTTP` for a
  url entry), the initialize handshake, the tool list, and the `tools/call`
  round-trip. `READ_TIMEOUT` is a **stdio** knob - the gem's HTTP transport
  accepts no read timeout (its knobs bound a message size and a reconnection
  budget), so an HTTP connection uses the gem's own defaults. It does NOT
  `require "mcp"` itself; the `::MCP::` constants resolve at call time, after
  Harness required the gem.
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
- `Harness#close_mcp` closes every connection this run opened. The CLI calls it
  on shutdown and on a mid-run `/resume` rebuild (the run being replaced owns its
  own servers).

## Consent

An MCP tool runs like a built-in tool - **no per-call dialog** - because the USER
declared the server in the config. The server is the trust boundary the user
chose - and with issue #402 that boundary is now something the user pointed at
with a URL, not only a program they can inspect on disk. Two consequences of a
remote server are worth naming:

- its `tools/list` answers with **arbitrary tool schemas** that go straight into
  `tools_payload`, and its `tools/call` answers with **arbitrary result text**
  that goes straight into the model chain (only base64 images are withheld).
  Nothing validates either side.
- an MCP url is **not** a `web.fetch` host. The two consent axes stay separate:
  `web.fetch`'s `allowed_hosts.yml` grant and its address guards (loopback /
  private / link-local refusal) do NOT gate an MCP connection, and an MCP
  server's tools are not reached through `web.fetch`. A url the user wrote in
  `mcp_servers:` is the authorization for that one connection.

An MCP call is not a shell command, so the `run.command` disaster denylist does
not apply to the call itself; nothing here weakens that denylist.

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
