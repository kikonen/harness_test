# frozen_string_literal: true

# Repro for "undefined method 'request_uri' for an instance of URI::Generic".
# From a fresh clone:
#   BUNDLE_GEMFILE=Gemfile bundle exec ruby analysis/uri-request-uri/repro.rb
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "llm/openai_backend"
require "model_config"
require "harness_config"
require "uri"

def report(label, config)
  backend = LLM::OpenAIBackend.new(config, logger: nil)
  uri = backend.send(:build_uri)
  puts format(
    "%-34s base_url=%-26s build_uri=%-34s request_uri=%s",
    label,
    backend.base_url.inspect,
    uri.class,
    uri.request_uri.inspect)
rescue HarnessError => e
  # What #556 asks for: a stated config error instead of a NoMethodError from
  # inside the transport.
  puts format("%-34s CONFIG ERROR: %s", label, e.message)
end

def profile(label, hash)
  report(label, ModelConfig.new(**HarnessConfig.new(models: [hash]).models.first))
rescue HarnessError => e
  puts format("%-34s CONFIG ERROR (config read): %s", label, e.message)
end

# A run with no endpoint at all: the first prompt used to die as NoMethodError
# in the task thread, on every retry, looking stuck rather than mis-configured.
report("no url (raw -m id)", ModelConfig.new(api: "openai"))
# A profile that declares no url is refused where the config is read.
profile("profile with no url", { name: "nohost" })
# A profile is refused when it carries no model: (#572) or no id.
profile("profile with no id", { url: "http://host.test/v1" })
profile("profile with no model", { id: "noModel", url: "http://host.test/v1" })
# A non-http scheme is a config error too, not a connect failure.
profile("profile with a ws url", { name: "ws", url: "ws://host.test/v1" })
# For contrast, the same call on a URI built from a configured url:
report("url configured", ModelConfig.new(api: "openai", base_url: "https://host.example/v1"))
