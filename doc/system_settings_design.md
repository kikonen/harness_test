# SystemSettings design

The run's single source of resolved CONFIG: a typed view + behavior layer over
the resolved CLI options hash, which it OWNS. Owned by the CLI and handed to
every Harness (sub-agents included) as the one settings object, so no other
object carries or reads a raw options hash.

Settings carries the run config and the shared model CATALOGUE (profiles,
default, the selected model name); it carries NO per-connection model fields.
The live model / endpoint / sampling values live only in each Harness' own
ModelConfig, seeded from the resolved profile - a sub-agent shares this one
settings object, so putting a per-connection field there would couple every
agent to it.

## One access route: named accessors only

Harness, its collaborators, the tools and CommandRunner all read config by name
(compact_*, retry_*, yolo?, the model catalogue/selection, the consent
postures). The raw options hash is never re-exposed - there is no single-key
[] reader/writer, because handing a key back through the raw hash is how the
whole mutable bag would slip back in.

## Postures

- The planning posture is deliberately NOT a settings toggle. It is
  per-conversation Harness state - settings is run-wide and shared with every
  agent, so a mutable [PLAN] toggle here would force every sub-agent into
  planning mode at once. Harness owns it, seeded from `plan_seed?`.
- `denylist_safe_approve?` is config-only (no live toggle), is NOT part of
  `command_mode_label`, and is only meaningful while the safety check is on.
  Rationale: doc/denylist_safe_approve_design.md.
- `restore_persisted` applies only the keys a session carries, so a session
  saved before a posture existed keeps the config value; the saved choice wins
  over config. command_safety_auto_approve, the denylist flag and plan are
  config-only (never saved), so they are not touched there.
