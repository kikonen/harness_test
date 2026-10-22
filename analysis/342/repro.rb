# frozen_string_literal: true
# Issue #342: the configured system_file is read unnormalized and poisons the chain.
# Run from the repo root: ruby analysis/342/repro.rb
# Expected: construction ok; prompt valid_encoding? false
#           chain JSON: JSON::GeneratorError: source sequence is illegal/malformed utf-8
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../lib/harness"

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, ".harness"))
  File.binwrite(File.join(dir, "sys.txt"), "You are a caf\xe9 helper\n")
  h = Harness.new({ system_file: File.join(dir, "sys.txt"), num_ctx: 1024, auto_save: false },
                  FileList.new([], workdir: dir))
  puts "construction ok; prompt valid_encoding? #{h.session.system_prompt.valid_encoding?}"
  h.session.add_user("go")
  begin
    JSON.generate(h.session.messages)
  rescue StandardError => e
    puts "chain JSON: #{e.class}: #{e.message[0, 50]}"
  end
end
