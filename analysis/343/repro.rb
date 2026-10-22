# frozen_string_literal: true

# Issue #343: a corrupt session.json resumes "successfully" then breaks every save,
# and a corrupt session vanishes silently from /sessions.
# Run from the repo root: ruby analysis/343/repro.rb
# Expected:
#   list ids -> ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]   (the bad-JSON session is gone)
#   read_session(bad JSON) -> JSON::ParserError: ...
#   read_session(invalid byte) ok, valid_encoding? false
#   JSON.generate -> JSON::GeneratorError
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../lib/session_locator"

Dir.mktmpdir do |dir|
  sd = File.join(dir, ".harness", "sessions")
  id1 = "11111111-2222-3333-4444-555555555555"
  FileUtils.mkdir_p(File.join(sd, id1))
  File.write(File.join(sd, id1, "session.json"), "{not json,,}")
  id2 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  FileUtils.mkdir_p(File.join(sd, id2))
  # The content carries an invalid byte (7d e9 = "}\xe9"), which is the point.
  body = %({"session_id":"#{id2}","messages":[{"role":"user","content":"caf}\xe9"}]})
  File.binwrite(File.join(sd, id2, "session.json"), body)
  loc = SessionLocator.new(dir)
  puts "list ids -> #{loc.list.map { |e| e[:id] }.inspect}"
  begin
    loc.read_session(id1)
  rescue StandardError => e
    puts "read_session(bad JSON) -> #{e.class}: #{e.message[0, 50]}"
  end
  c = loc.read_session(id2)[:messages].last[:content]
  puts "read_session(invalid byte) ok, valid_encoding? #{c.valid_encoding?}"
  begin
    JSON.generate([c])
  rescue StandardError => e
    puts "JSON.generate -> #{e.class}"
  end
end
