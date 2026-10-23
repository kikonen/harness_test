# frozen_string_literal: true

# Issue #342: the configured system_file is read unnormalized and poisons the chain.
# Run from the repo root: ruby analysis/342/repro.rb
# Expected before the fix: "construction ok; prompt valid_encoding? false" and
#   chain JSON: JSON::GeneratorError - the session save dies on the same byte.
# Expected after the fix:  valid_encoding? true and chain JSON: ok.
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../lib/harness"

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, ".harness"))
  File.binwrite(File.join(dir, "sys.txt"), "You are a caf\xe9 helper\n")
  opts = { system_file: File.join(dir, "sys.txt"), num_ctx: 1024, auto_save: false }
  h = Harness.new(opts, FileList.new([], workdir: dir))
  prompt = h.session.system_prompt
  puts "construction ok; prompt valid_encoding? #{prompt.valid_encoding?}"
  h.session.add_user("go")

  status = begin
    JSON.generate(h.session.messages)
    "ok"
  rescue StandardError => e
    "#{e.class}: #{e.message[0, 50]}"
  end
  puts "chain JSON: #{status}"
end
