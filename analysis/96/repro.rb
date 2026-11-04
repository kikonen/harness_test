# frozen_string_literal: true

# Issue #96: 'git branch' by itself is safe, 'git branch -D' is not, yet the
# consent dialog offered "Always allow 'git branch', 'git log'" for a run that
# only READ. This script CLASSIFIES command strings - nothing is executed,
# nothing is granted, no dialog is opened - so it runs from a fresh clone:
#   ruby analysis/96/repro.rb
#
# Three things are measured for each command:
#   candidates  what the dialog would offer as an "Always allow" grant
#   disaster?   the denylist verdict (a disaster keeps the dialog everywhere)
#   covered?    whether a STORED prefix (given on the right) auto-approves it
require "tmpdir"

require_relative "../../lib/command_allowlist"

# What the dialog offers as "Always allow" options for a command.
CANDIDATE_COMMANDS = [
  "git branch --show-current && git log --oneline -3", # the report's own line
  "git branch",
  "git branch --show-current",
  "git branch -a",
  "git log --oneline -5",
  "tail -5"
].freeze

# A stored 'git branch' grant against commands that a prefix grant then covers.
STORED = "git branch"
COVERED_TESTED = [
  "git branch",
  "git branch -a",
  "git branch -d tmp-branch",
  "git branch -D tmp-branch",
  "git branch -D main",
  "git branch --delete x",
  "git branch -m old new",
  "git branch -c x y"
].freeze

# Each candidate SHAPE the dialog offers, and the scope sentence it states
# (grant_scope_note). A run-shaped grant is flag-blind; a grant that names a
# flag or argument is pinned to exactly those words.
CANDIDATE_KINDS = [
  "git", "git branch", "git branch -D", "git log --oneline",
  "cd C:/work/x", "ruby -c", "bin/rspec", "bin/*"
].freeze

Dir.mktmpdir do |dir|
  puts "candidates offered per command (the grant the user is being asked to save):"
  CANDIDATE_COMMANDS.each do |cmd|
    options = CommandAllowlist.extract_prefix_options(cmd)
    puts format("  %-46s %s", cmd, options.inspect)
  end

  puts
  puts "disaster? verdict for the mutating forms (denylist floor):"
  COVERED_TESTED.each do |cmd|
    puts format("  %-34s disaster? %s", cmd, CommandAllowlist.disaster?(cmd))
  end

  puts
  puts "a stored #{STORED.inspect} grant - which commands does it auto-approve?"
  CommandAllowlist.new(dir).tap do |list|
    list.add(STORED)
    COVERED_TESTED.each do |cmd|
      puts format("  %-34s allowed? %s", cmd, list.allowed?(cmd))
    end
  end

  puts
  puts "the same grant against a DIFFERENT command tree (must stay ungranted):"
  CommandAllowlist.new(dir).tap do |list|
    list.add(STORED)
    %w[git checkout -b x git log --oneline git remote remove origin].each do |cmd|
      puts format("  %-34s allowed? %s", cmd, list.allowed?(cmd))
    end
  end

  puts
  puts "the scope sentence each candidate shape states (grant_scope_note):"
  CANDIDATE_KINDS.each do |kind|
    note = CommandAllowlist.grant_scope_note(kind)
    puts format("  %-20s %s", kind.inspect, note)
  end
end
