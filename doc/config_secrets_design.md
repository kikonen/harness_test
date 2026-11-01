# Config secrets: `${NAME}` reads a secret from the environment (issue #422)

Why a model bearer token or an MCP credential can be written in `config.yml` as
`${OPENAI_TOKEN}` instead of the literal secret, and why the expansion is a
plain ENV read and never ERB.

---

## The leak this closes

`config.yml` is a file you open in an editor, paste into a chat, and that a
screen recorder or a video of your desktop captures. A bearer token written as
literal text there is readable in every one of those. The harness already keeps
the secret out of the places that *output* it (the REQ log lines name only the
URI and body size, never the `Authorization` header; `session.json` saves model
state by NAME, never the token; `/models` prints name / model / url / api, never
the token). The one place a literal token *is* visible is the config file itself.

`token: ${OPENAI_TOKEN}` puts only the **variable name** in the file. The secret
lives only in the process environment. A screenshot or a paste of the config
then shows `token: ${OPENAI_TOKEN}` and leaks nothing.

## The syntax: `${NAME}`, a plain ENV lookup

`HarnessConfig::ENV_REF` is `/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/`. `#expand_env`
replaces every match with `ENV[name]`, applied to:

- a model profile's `token:` (whole value or a `${NAME}` inside it),
- an `mcp_servers` entry's `env:` values (a stdio server's environment),
- an `mcp_servers` http entry's `headers:` **values** (e.g.
  `Authorization: "Bearer ${API_KEY}"`).

It is deliberately **constrained**:

- Only a legal identifier between `${` and `}` is a reference. `foo${bad-name}`
  stays literal, and a value with a bare `$` (`sk-pl$ain`) is untouched - real
  API keys often contain `$`, and mistaking one for a reference would corrupt
  the key.
- A value with no `${NAME}` is returned unchanged, so every plain config value
  behaves exactly as before.

## Never eval / never ERB

The owner noted ERB as an alternative. It was rejected on purpose. Evaluating a
config value as Ruby (or even ERB, which evaluates its tags) would let anything
written into `config.yml` run code inside the harness at startup - a new code-
execution surface on a feature whose whole point is reducing risk. `expand_env`
does one thing: a regex match and a `ENV[]` read. No interpreter, no `eval`,
no method call on user text.

## Missing variable: a config error, not a silent empty

If `${NAME}` is referenced and `NAME` is not in the environment, `expand_env`
raises `HarnessError` naming the variable. Expanding to `""` instead would let a
forgotten `export` surface later as an opaque 401 from the model or a failed MCP
connect - the kind of failure that reads as "the server is broken" rather than
"you did not set the variable the config points at". Failing at startup, with
the variable's name, is the conservative choice for a security setting.

## Why it stays out of every other leak path

Expansion happens once, at config parse, producing the `@models` and
`@mcp_servers` the harness already carries. Nothing new is stored:

- `#to_h` returns the **raw** parsed hash, which holds only the `${NAME}`
  reference - never the expanded secret.
- `session.json` saves the model by name and a fixed posture-key list; it never
  dumps `options[:token]`, `options[:model_profiles]`, or MCP headers (verified:
  `Session#to_h` and `SessionManager#save_session` carry neither). So the fix
  removes the secret from `config.yml` without moving it into `session.json`.
- The expanded secret then lives only in memory, in `options[:token]` and the
  MCP connection's `env` / `headers`, consumed at request/spawn time.
