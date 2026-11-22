# Model identity: a profile has an id, a display name, and a model (issues #556, #572)

Where the harness gets the value it sends in a request's `model:` field, why a
profile carries `id:` + `name:` + `model:` instead of one overloaded `name:`, and
where a missing endpoint is reported.

Verified against the code on branch `fix/556-model-profile-name-is-the-model`.

---

## Three roles, three keys

A model profile is the harness' whole description of a model:

```yaml
models:
  - id: local                        # identity: what a selection resolves by
    name: Local Qwen                 # optional display label (defaults to the id)
    model: qwen2.5-coder:7b          # the model the endpoint is asked for
    url: http://localhost:11434/v1   # the endpoint
    api: openai
```

- **id** - what `-m`, `default_profile_id` and `/model <id>` select by, and what a
  saved session stores (`active_profile_id`). It is unique: `normalize_models`
  refuses an id used by more than one entry, because a duplicate makes a selection
  and a resumed run silently ambiguous.
- **name** - a display label only: the spinner, the modeline, the startup banner
  and the `/models` row. It defaults to the id and may repeat across profiles.
- **model** - what the request body's `model:` field carries: a model name the
  endpoint answers for (#572). It is never the id or the name; only the profile
  knows which model its server answers for.

The normalized profile is a `ModelProfile` value object (`lib/model_profile.rb`),
not a scattered hash: it owns the id/name/model/url roles and answers its own
validity through `#valid?` / `#valid!`, so no consumer re-derives one role from
another. Backward compatibility: a config that predates `id:` keys its entries
with `name:` alone - `ModelProfile` reads `name` as the id when `id` is absent,
and `default_model:` is still read as the startup profile. `model:` is a required
key, so a name-only config still needs it; no value is ever inferred from an id
or a name.

## The bug #556 fell into

`model:` beside `name:` let a run hold *a name with no model* or *a model with
no name*, and neither was checked until the request was built: `build_uri` was
`URI("#{base_url}#{endpoint_path}")`, and with `base_url` nil that is a bare
path - `URI::Generic`, which has never had `request_uri` or `host` (measured on
ruby 4.0.7). The first prompt died as
`NoMethodError: undefined method 'request_uri' for an instance of URI::Generic`
in the task thread, on every retry, so the run looked stuck rather than
mis-configured. Repro: `analysis/uri-request-uri/repro.rb`.

The first cut of #556 declared the profile's `name:` to be both the selection key
and the wire model and deleted the `model:` alias. That made renaming a profile
impossible without renaming what the endpoint is asked for, so the identity was
split into id + name. Issue #572 then settled the wire value: the profile's own
`model:`, never the id or the name.

## Where each identity lives

| Fact | Owner | Notes |
| --- | --- | --- |
| the catalogue (`models:`) | `HarnessConfig` -> `SystemSettings#model_profiles` | run-wide, fixed config, shared by every agent (#286); each entry normalized to a `ModelProfile` |
| the selection (`-m`, nil = config default) | `CLIOptions#apply_profile_tracking` -> `SystemSettings#active_profile_id` | `nil` means "whatever the default profile is", so a session outlives a changed default |
| the live connection (profile id, display name, model, endpoint, sampling) | `ModelConfig#active_profile_id`, `#active_profile_name`, `#model`, `#base_url`, ... | per Harness (#286): a `/model` switch must not flip every agent at once |
| the request body's `model:` field | `LLM::OpenAIBackend#build_body`, `LLM::OllamaBackend#build_body` | reads `@config.model`, the profile's `model:` |

`SystemSettings#resolved_profile_id` (`active_profile_id || default_profile_id`)
is the single resolver every consumer uses; `resolved_profile_name` shows the
profile's label through the same resolver, so display and selection cannot
disagree.

`ModelConfig` is *live state*: `from_settings` seeds the id from the selection
(nil when the config default is active - that nil is what a session saves, so a
later change of the default reaches the resumed session), and seeds `model:` from
the resolved profile. There is no profile-less raw-id run: a model is selected
from a configured profile only, so `-m`/`default_profile_id` with no `models:` is
a startup config error. `HarnessFactory` writes the resolved default profile's id,
name and model into a fresh job's `ModelConfig`.

## What is checked, and where

1. **Reading the config** (`HarnessConfig#normalize_models`): each entry becomes a
   `ModelProfile`, which validates its own `id`/`model`/`url` (url must be `http(s)`)
   through `#valid!`; `HarnessConfig` then enforces the one cross-entry rule - no
   two profiles share an id - and that `default_profile_id` names a configured
   profile. Each failure is a `HarnessError` at startup. The scalar coercions
   (`nonblank`, int/float/bool coercion, `require_http_url`, `${ENV}` expansion)
   live in `ConfigScalar` (`lib/config_scalar.rb`), shared with `mcp_servers`.
2. **Building the request** (`LLM::BaseBackend#build_uri`): a `ModelConfig` can
   still be built by hand (a spec), so the transport re-checks only the endpoint -
   no `base_url` names the profile and says which key is missing; a url with no
   host says it is not a full endpoint. A missing model is never re-guessed: the
   config already refused it. Either endpoint failure is a `HarnessError`, which
   `CLI` prints as `Error: ...` instead of a task-thread crash.

`doc/harness_job_design.md` covers who owns the model state (#286); this file
covers what a profile's id, name and model mean and where a missing endpoint is
reported.
