# frozen_string_literal: true
# Issue #344: SafetyCheck maps verdict lines by POSITION, so one extra model line
# shifts every verdict onto the wrong command.
# Run from the repo root: ruby analysis/344/repro.rb
# Expected: {"ruby -c a.rb" => "Here are my verdicts:",
#            "rm -rf /tmp/x" => "safe: syntax check"}   (the destructive one is safe)
require_relative "../../lib/safety_check"

client = Class.new do
  def chat(*, **)
    verdicts = "Here are my verdicts:\nsafe: syntax check\ndangerous: deletes files"

    { choices: [{ message: { content: verdicts } }], usage: {} }
  end
end.new

chain = [{ role: "system", content: "s" }, { role: "user", content: "go" }]
puts SafetyCheck.run(client, chain, ["ruby -c a.rb", "rm -rf /tmp/x"]).inspect
