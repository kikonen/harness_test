# Tool-result images (issue #449)

An MCP server may answer a `tools/call` with **image content blocks** (a
Blender screenshot, a rendered view). The harness' message chain is text-only,
so the question is what the model is actually given when a tool returns
pixels. This document owns the decision; `ImageDelivery` is the single place
that makes it, and the MCP adapter, `Harness` and the LLM backends may not
each invent their own answer.

## The bug this fixes

`ServerConnection.content_to_text` collapsed every image block to a label, so
every Blender screenshot reached the model as `[image: image/png]` with no
pixels and no path - indistinguishable from "the server is broken". Measured
live in a session: `blender.get_screenshot_of_area_as_image` returned exactly
that. A second defect sat underneath: the code read the wire spelling
`mimeType`, but mcp 1.8.2 hands the client the gem's keyword spelling
`mime_type`, so even the mime type was lost (a stdio round trip through a
server that DID name its type reported `[image: unknown]`).

The sizes are why "just inline it" is not an answer (real Blender PNGs):

| file | decoded | base64 | ~tokens |
| --- | --- | --- | --- |
| thumbnail | 81 KB | 109 KB | ~27 K |
| a car render | 433 KB | 578 KB | ~144 K |
| a full render | 1.23 MB | 1.64 MB | ~410 K |

against a default `num_ctx` of 65 536. One big render is more than six times
the context window, so inlining can only ever be a **budgeted** decision.

## The shape: ToolResult

Every built-in tool returns a String and the chain is text-only, so an image
needs a value that says "here is the text, and here are bytes that are NOT
text". `ToolResult` (lib/tool_result.rb) carries `text` plus `images`;
`ToolResult::Image` carries `server`, `tool`, `mime_type` and the DECODED
`bytes`.

INVARIANT: image bytes never enter the message chain, the session JSON or
`TextNormalizer`. They are a **byte container**, not text in some encoding -
normalizing them would mangle them (`doc/encoding_design.md`). They are
BINARY-tagged, the same rule as a child-process pipe buffer.

`ServerConnection.content_to_result` returns a plain String when the result
carried no images (the shape every built-in already returns) and a `ToolResult`
when it did. A block whose data will not decode is NAMED in the text
(`unpack1("m")` silently ignores characters outside the base64 alphabet, so
corrupt data would otherwise spill as a plausible-looking broken file).

## Vision is a per-model fact, not a harness fact

Whether the model may be SENT images is a property of the ACTIVE model profile,
declared in the config as `vision:` on a profile (issue #449). The harness never
guesses that an unconfigured model can see:

- no profiles configured (a raw `-m` id) -> text-only;
- a profile without `vision: true` -> text-only;
- a profile with `vision: true` -> images may be inlined, within the budget.

`SessionManager#vision?` is read **per turn**, so a `/model` switch between a
vision and a text profile changes what the NEXT tool result does with its image.
The backend re-checks it too (`BaseBackend#images_supported?`): a profile that
did not declare vision never receives an image payload even if one somehow
reached the chain. That is defense in depth, and it is what keeps a stray
payload from becoming a megabyte data URI to a text model.

## The blob store (why .harness/content and not tmp/)

A session records the PATH of the artifact it was given. `tmp/` is per-machine
scratch that is gone in the next session (the project rule), so a saved session
would name a path that no longer exists. The bytes therefore live under harness
state: `.harness/content/<session-id>/` (config `mcp_images: dir:` overrides
the base). One directory per session id, so a resumed run (same id) finds its
own blobs again.

Two consequences the model must be told about, because they are not guessable:

- the file is **native bytes, not base64** (the transport form is re-encoded per
  request; the stored artifact is the file itself);
- `.harness/` is a **sensitive path** (`doc/sensitive_paths_design.md`), so the
  file tools will not open it. The result text says "reach it with the shell,
  not the file tools" - a silent denial on a path the model was pointed at reads
  as a harness bug.

The MODEL writes nothing there; the harness writes it and hands over the
workdir-relative path. `ImageStore#save` sanitizes the name (it comes from a
remote server's tool list) so no separator or `..` can turn a spill into a
write outside the store.

`save` names each blob `<server>_<tool>_<index>`, where the index is bumped
past any file already in the dir. A resumed run reuses its session's dir with a
fresh counter, so its first spill would otherwise land on a blob the earlier
run wrote (issue #276); skipping taken indexes means a new spill never clobbers
a path a saved session already names. Uniqueness is checked against the
filesystem, not the in-memory counter (which is per-run and resets on resume).

## The delivery decision (ImageDelivery)

ONE `ImageDelivery` object per turn. Every image is **always spilled** when the
write is possible - that is the durable reference and the form a text model can
act on. Inlining (base64 into the next request) is the ADDITION a budget allows.

Three budgets, from `mcp_images:` (config-level, or a profile's own block):

- `inline_max_bytes` - one image over this many DECODED bytes is spilled only.
- `inline_max_images` - images inlined per single tool result.
- `inline_max_tokens` - worst-case token cost of the inlined images.

The token budget is a **turn** budget, not a per-result one: five screenshots
across five tool results must not jointly smuggle 200K tokens into a 65K window
just because each result looked affordable on its own. That is why the object
carries `@turn_tokens` and lives for exactly one turn.

Each image gets one mode:

- `:inline` - vision profile, every budget met. Spilled AND base64 into the request.
- `:file` - the model cannot see it (or it is over a budget), but the bytes are stored.
- `:drop` - nothing could be done (no vision, a budget exceeded, AND the store write failed).

`ImageDelivery#describe` is the text the model reads: one line per image naming
its fate. Never a bare `[image: ...]` - the model must be able to tell "the
server sent nothing usable" from "this model cannot see images", and must be
told where the bytes are when it cannot see them.

## Base64 lives only in the live working chain

`Harness#call_llm` attaches the inlined payloads to the tool message as
`images: [{ mime_type:, base64: }]`. This is deliberate: `Session#estimate_tokens`
counts them, so the token estimate and the in-loop compact trigger SEE the cost
- an uncounted 1.6 MB data URI is four times a 65536-token window, and the one
thing that would overflow the window would never trigger compaction.

The payloads are then stripped: once a request has carried them (the model has
seen them - re-sending would repeat the megabytes in every later request of the
turn) and again at the commit boundary. A committed chain is text state, so no
base64 belongs in it or in a session file. The text beside them - the line that
names the stored file - is what survives.

## On the wire

The chain stays backend-agnostic (`images:` beside the content); each endpoint
wants a different shape, so the conversion is in the backends:

- **OpenAI-compatible** (`OpenAIBackend#serialize_messages`): the tool turn
  becomes a content ARRAY - a text part plus one `image_url` part per image, in
  the data-URI form (no separate upload endpoint).
- **native /api/chat** (`OllamaBackend#serialize_messages`): a top-level
  `images` list of BARE base64 strings (Ollama's own multimodal field), no data
  URI and no content array.

In both, the canonical `images:` key is stripped from the wire message: it is
this harness' chain shape, not a field any endpoint accepts. A non-vision
profile gets the payload removed entirely, not forwarded.

## Config

Per-profile `vision:` (the model can see images) and either a global or a
per-profile `mcp_images:` block (how much it may be sent). A profile that omits
the block leaves it nil - like `streaming:` - so it inherits the global block
instead of shadowing it with the built-in defaults. A limit of 0 or a negative
value is a config error: a budget is not "no budget", it is a typo, and a silent
"inline nothing" would read as a broken MCP image path.

## What a text model can still do

A text-only profile is not blind to the image: it gets the file path and can act
on it through the shell (for example hand it to another tool). The failure mode
this design removes is not "the model cannot see the picture" - it is "the model
was told a picture existed and given nothing usable, with no idea why".
