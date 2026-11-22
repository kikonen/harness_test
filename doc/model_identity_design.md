# Model identity: a profile has an id and a display name (issue #556)

Where the harness gets the model id it sends in a request, why a profile carries
an id and a name instead of one overloaded `name:`, and where a missing endpoint
is reported.

Verified against the code on branch `fix/556-model-profile-name-is-the-model`
(post-`cc63a35` master).

---

## Two roles, two keys

A model profile is the harness' whole description of a model:

```yaml
models:
  - id: local                        # identity: selection key AND the wire value
    name: Local Qwen                 # optional display label (defaults to the id)
    url: http://localhost:11434/v1   # the endpoint it is asked for
    api: openai
```

- **id** - what `-m`, `default_profile_id` and `/model <id>` select by, what a
  saved session stores (`active_profile_id`), and the value the request body
  names the model with. It is unique: `HarnessConfig#normalize_models` refuses
  an id used by more than one entry, because a duplicate makes a selection and a
  resumed run silently ambiguous.
- **name** - a display label only: the spinner, the modeline, the startup banner
  and the `/models` row. It defaults to the id and may repeat across profiles.

Backward compatibility: a config that predates `id:` keys its entries with
`name:` alone - `require_profile_id` and `SystemSettings#find_profile` fall back
to `name` for the id, and `default_model:` is still read as the startup profile.
A name-only profile therefore behaves exactly as before (id == name). The old
`model:` key - a per-profile alias for the wire id - is retired and dropped at
normalization.

The intermediate stage (first cut of #556) declared the profile's `name:` to be
both the selection key and the wire model and deleted the `model:` alias. That
made a rename of a profile impossible without also renaming what the endpoint is
asked for, so the identity was split into id + name instead. What value belongs
on the wire when a real server wants a name different from the selection key is
open issue **D**; today the id is the wire value.

## The bug #556 fell into

`model:` beside `name:` let a run hold *a name with no model* or *a model with
no name*, and neither was checked until the request was built: `build_uri` was
`URI("#{base_url}#{endpoint_path}")`, and with `base_url` nil that is a bare
path - `URI::Generic`, which has never had `request_uri` or `host` (measured on
ruby 4.0.7). The first prompt died as
`NoMethodError: undefined method 'request_uri' for an instance of URI::Generic`
in the task thread, on every retry, so the run looked stuck rather than
mis-configured. Repro: `analysis/uri-request-uri/repro.rb`.

## Where each identity lives

| Fact | Owner | Notes |
| --- | --- | --- |
| the catalogue (`models:`) | `HarnessConfig` -> `SystemSettings#model_profiles` | run-wide, fixed config, shared by every agent (#286); each entry normalized to carry both `id:` and `name:` |
| the selection (`-m`, nil = config default) | `CLIOptions#apply_profile_tracking` -> `SystemSettings#active_profile_id` | `nil` means "whatever the default profile is", so a session outlives a changed default; a fallback never writes the id |
| the live connection (profile id, display name, endpoint, sampling) | `ModelConfig#active_profile_id`, `#active_profile_name`, `#base_url`, ... | per Harness (#286): a `/model` switch must not flip every agent at once |
| the id in the request body | `LLM::OpenAIBackend#build_body`, `LLM::OllamaBackend#build_body` | reads `@config.active_profile_id` |

`SystemSettings#resolved_profile_id` (`active_profile_id || default_profile_id`)
is the single resolver every consumer uses; `resolved_profile_name` shows the
profile's label through the same resolver, so display and selection cannot
disagree.

`ModelConfig#active_profile_id` is *live state*: `ModelConfig.from_settings`
seeds it from the selection, which is nil when the config default is active -
that nil is what a session saves, so a later change of the default still reaches
the resumed session. Only a `/model` switch (`apply_profile`) writes the id.
`active_profile_name` is display state and is seeded on every build
(`write_profile_name`), falling back to the resolved id for a profile-less run.

## What is checked, and where

1. **Reading the config** (`HarnessConfig#normalize_models`): a profile must
   have an `id` (or a `name:` that predates ids) and a `url`, the url must be
   `http(s)`, and no two entries may share an id. Each failure is a
   `HarnessError` at startup - "model profile 'x' needs a 'url' (there is no
   built-in endpoint default)". `require_http_url` is shared with `mcp_servers`
   and takes the entry's label as an argument, so both transports report which
   entry was bad.
2. **Building the request** (`LLM::BaseBackend#build_uri`): a `ModelConfig` can
   still be built by hand (a profile-less `-m <raw id>`, a spec), so the
   transport re-checks - no `base_url` names the profile and says which key is
   missing; a url with no host says it is not a full endpoint. Either is a
   `HarnessError`, which `CLI` prints as `Error: ...` instead of a task-thread
   crash.

`doc/harness_job_design.md` covers who owns the model state (#286); this file
covers what a profile's id and name mean and where a missing endpoint is
reported.
