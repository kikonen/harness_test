# frozen_string_literal: true

# Issue #341: a non-UTF-8 harness.md crashes the run at startup.
# Run from the repo root: ruby analysis/341/repro.rb
# Expected before the fix: startup: Encoding::CompatibilityError: invalid byte sequence in UTF-8
# Expected after the fix:  startup ok + the repair named, and the mid-session reload
#                          path (check_rules_reload) survives the same file.
require "tmpdir"
require "fileutils"
require_relative "../../lib/harness"

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, ".harness"))
  damaged = "rule caf\xe9 keep 90 cols\n".dup.force_encoding(Encoding::UTF_8)
  File.binwrite(File.join(dir, "harness.md"), damaged)

  begin
    h = Harness.new({ num_ctx: 1024 }, FileList.new([], workdir: dir))
    puts "startup ok; prompt valid_encoding? #{h.session.system_prompt.valid_encoding?}"
    puts "repair named: #{h.rules_repair_note}"
    # Mid-session shape: the file goes bad while the run is live, and the same
    # read runs again on the next prompt.
    File.binwrite(File.join(dir, "harness.md"), "rule caf\xe9 reload\n")
    past = Time.now - 120
    File.utime(past, past, File.join(dir, "harness.md"))
    h.session_manager.check_rules_reload
    puts "reload ok; prompt valid_encoding? #{h.session.system_prompt.valid_encoding?}"
  rescue StandardError => e
    puts "startup: #{e.class}: #{e.message}"
  end
end
