# frozen_string_literal: true

# Repro for "undefined method 'request_uri' for an instance of URI::Generic".
# From a fresh clone:
#   BUNDLE_GEMFILE=Gemfile bundle exec ruby analysis/uri-request-uri/repro.rb
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "llm/openai_backend"
require "model_config"
require "uri"

def attempt(label, config)
  backend = LLM::OpenAIBackend.new(config, logger: nil)
  uri = backend.send(:build_uri)
  puts format(
    "%-34s base_url=%-26s build_uri=%-34s %s",
    label,
    backend.base_url.inspect,
    "#{uri.class}",
    begin
      "request_uri=#{uri.request_uri.inspect}"
    rescue => e
      "RAISES #{e.class}: #{e.message}"
    end)
end

# A profile WITHOUT 'url:' - ModelConfig documents this as legitimate: a raw -m
# id, or a profile that names no endpoint ("there is no built-in endpoint default").
attempt("no url (raw -m id)", ModelConfig.new(model: "mymodel", api: "openai"))
attempt("profile with no url", ModelConfig.new(model: "mymodel", api: "ollama"))
# For contrast, the same call on a URI built from a configured url:
attempt(
  "url configured",
  ModelConfig.new(
    model: "m",
    api: "openai",
    base_url: "https://host.example/v1"))
