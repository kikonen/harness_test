# Model identity: a profile's name IS the model (issue #556)

Where the harness gets the model id it sends in a request, why a profile has one
identity and not two, and where a missing endpoint is reported.

Verified against the code on branch `fix/556-model-profile-name-is-the-model`
(post-`cc63a35` master).

---

## One identity, in one place

A model profile is the harness' whole description of a model:

```yaml
models:
  - name: local                       # the model, and the selection key
    url: http://localhost:11434/v1    # the endpoint it is asked for
    api: openai
```

`name:` is the id sent in the request body AND the key `-m` / `default_model` /
`/model <name>` select by. There is no second name: the retired `model:` key
used to be a per-profile alias for the id, and a `ModelConfig` value beside
`active_model` held it.

That split was the shape #556 fell into. A run could hold *a name with no model*
or *a model with no name*, and neither was checked until the request was built:
`build_uri` was `URI("#{base_url}#{endpoint_path}")`, and with `base_url` nil
that is a bare path - `URI::Generic`, which has never had `request_uri` or `host`
(measured on ruby 4.0.7). The first prompt died as
`NoMethodError: undefined method 'request_uri' for an instance of URI::Generic`
in the task thread, on every retry, so the run looked stuck rather than
mis-configured. Repro: `analysis/uri-request-uri/repro.rb`.

The harness never holds a "wire id" beside a display name. It asks the endpoint
for the profile's name, and the server answers for that model or says it has no
such model - which is the whole point of `models:` being a config.

## Where each identity lives

| Fact | Owner | Notes |
| --- | --- | --- |
| the catalogue (`models:`) | `HarnessConfig` -> `SystemSettings#model_profiles` | run-wide, fixed config, shared by every agent (#286) |
| the selection (`-m`, nil = config default) | `CLIOptions#apply_model_tracking` -> `SystemSettings#active_model` | `nil` means "whatever the config default is", so a session outlives a changed default |
| the live connection (name, endpoint, sampling) | `ModelConfig#active_model`, `#base_url`, ... | per Harness (#286): a `/model` switch must not flip every agent at once |
| the id in the request body | `LLM::OpenAIBackend#build_body`, `LLM::OllamaBackend#build_body` | reads `@config.active_model` |

`SystemSettings#selected_model_id` (profile's `model:` or the raw `-m` id) is
gone with the split.

`ModelConfig#active_model` is *live state*: `ModelConfig.from_settings` seeds it
from the selection, which is nil when the config default is active. That nil is
what a session saves, and `HarnessFactory#build_for` writes the resolved default
name into a job that was built fresh - so a saved job can still be looked up on
resume.

## What is checked, and where

1. **Reading the config** (`HarnessConfig#normalize_models`): a profile must
   have a `name` and a `url`, and the url must be `http(s)`. An entry that does
   not is a `HarnessError` at startup - "model profile 'x' needs a 'url' (there
   is no built-in endpoint default)". `require_http_url` is shared with
   `mcp_servers` and takes the entry's label as an argument, so both transports
   report which entry was bad.
2. **Building the request** (`LLM::BaseBackend#build_uri`): a `ModelConfig` can
   still be built by hand (a profile-less `-m <raw id>`, a spec), so the
   transport re-checks - no `base_url` names the model and says which key is
   missing; a url with no host says it is not a full endpoint. Either is a
   `HarnessError`, which `CLI` prints as `Error: ...` instead of a task-thread
   crash.

`doc/harness_job_design.md` covers who owns the model state (#286); this file
covers what one identity means and where a missing endpoint is reported.
