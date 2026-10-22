# frozen_string_literal: true

# Issue #341: a non-UTF-8 harness.md crashes the run at startup.
# Run from the repo root: ruby analysis/341/repro.rb
# Expected: startup: Encoding::CompatibilityError: invalid byte sequence in UTF-8
require "tmpdir"
require "fileutils"
require_relative "../../lib/harness"

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, ".harness"))
  File.binwrite(File.join(dir, "harness.md"), "rule caf\xe9 keep 90 cols\n")
  begin
    Harness.new({ num_ctx: 1024 }, FileList.new([], workdir: dir))
    puts "no raise?!"
  rescue StandardError => e
    puts "startup: #{e.class}: #{e.message}"
  end
end
