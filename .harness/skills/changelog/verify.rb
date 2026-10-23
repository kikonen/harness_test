#!/usr/bin/env ruby
# frozen_string_literal: true

# CHANGELOG.md regeneration check: the companion script of
# .harness/skills/changelog/SKILL.md, run as its step 7. READ-ONLY - it opens the
# changelog and the PR dataset, prints a verdict, and writes nothing.
#
#   ruby .harness/skills/changelog/verify.rb \
#     CHANGELOG.md tmp/keep/<n>/merged_prs.tsv <horizon_start> \
#     [doc_root] [--against <previous CHANGELOG.md>]
#
# Without --against only the shape rules are checked (the bootstrap run, where a
# whole-file rewrite is allowed). With --against the history rules are checked
# too: everything the previous file already said must survive byte-identically.
#
# The tsv rows are: number \t mergedAt(date) \t closing-issues \t title - exactly
# what step 1 of the skill pulls from gh. Exit 0 = PASS, 1 = FAIL.

MAX_LINE = 80
MAX_BULLET_LINES = 5
DATE_SECTION = /\A## (\d{4}-\d{2}-\d{2})(\s|$)/

def parse_rows(tsv_path)
  File.readlines(tsv_path).map do |line|
    num, date, _closes, title = line.chomp.split("\t")
    { num: num.to_i, date:, title: title.to_s }
  end
end

def nums(line)
  line.scan(/#(\d+)/).map { |m| m[0].to_i }
end

# sections -> [{date:, header:, body: [lines]}]; the preamble is everything
# before the first date section.
def parse_log(lines)
  sections = []
  current = nil
  preamble = []
  lines.each do |line|
    m = line.match(DATE_SECTION)
    if m
      current = { date: m[1], header: line.chomp, body: [] }
      sections << current
      next
    end
    if current
      current[:body] << line.chomp
    else
      preamble << line.chomp
    end
  end
  # A blank line that only separates two sections belongs to neither body, so it
  # is trimmed here; a blank line INSIDE a section body stays and is a fail.
  sections.each { |s| s[:body] = trim_trailing_blanks(s[:body]) }
  { preamble:, sections: }
end

def trim_trailing_blanks(body)
  body.pop while body.last.to_s.strip.empty?
  body
end

# Every line of the file in order: preamble, then each section's header followed
# by its body. Used for the whole-file checks (unreleased, subheadings, docs,
# line width) that are not scoped to one section.
def all_lines(parsed)
  parsed[:preamble] +
    parsed[:sections].flat_map { |s| [s[:header]] + s[:body] }
end

# A bullet block is the "- " line plus its wrapped continuation lines (indented).
def bullet_blocks(body)
  blocks = []
  body.each do |line|
    if line.start_with?("- ")
      blocks << [line]
    elsif blocks.any? && line.start_with?("  ")
      blocks[-1] << line
    elsif line.strip.empty?
      nil # already handled by the blank-line check
    else
      blocks << [nil, line]
    end
  end
  blocks
end

def horizon_of(merged, horizon_start)
  merged.select { |pr| pr[:date] >= horizon_start }
end

# Shape rules: date sections, one bullet per PR, wrapped continuation only,
# every horizon PR named once, no stale entry, no ## Unreleased, 80 columns.
def shape_fails(parsed, merged, horizon_start, log_path, doc_root)
  fails = []
  lines = all_lines(parsed)
  hnums = horizon_of(merged, horizon_start).map { |pr| pr[:num] }

  parsed[:sections].each do |s|
    blocks = bullet_blocks(s[:body])
    blocks.each do |block|
      if block[0].nil?
        fails << "STRAY line in #{s[:date]} " \
                 "(only a bullet or its continuation): #{block[1]}"
        next
      end
      next if block.size <= MAX_BULLET_LINES

      fails << "#{s[:date]}: bullet #{block[0][0, 20]} is #{block.size} lines " \
               "(max #{MAX_BULLET_LINES})"
    end
    blanks = s[:body].count { |l| l.strip.empty? }
    fails << "#{s[:date]}: #{blanks} blank line(s) inside a section" if blanks.nonzero?
  end

  bullets = parsed[:sections].flat_map { |s| s[:body].select { |l| l.start_with?("- ") } }
  # Array#tally takes NO block (it would be silently ignored), so map first:
  # primary maps each PR number to how many bullets carry it as their own
  # leading number.
  primary = bullets.map do |l|
    m = l.match(/\A- #(\d+)/)
    m && m[1].to_i
  end.compact.tally
  named = lines.flat_map { |l| nums(l) }.uniq

  horizon_of(merged, horizon_start).each do |pr|
    count = primary[pr[:num]] || 0
    if count.zero?
      fails << "MISSING ##{pr[:num]} (#{pr[:date]}) #{pr[:title]}"
    elsif count > 1
      fails << "DUP ##{pr[:num]} has #{count} bullets (one bullet per PR)"
    end
  end

  bullets.each do |l|
    named_prs = nums(l) & hnums
    next unless named_prs.size > 1 && named_prs.any? { |n| !(primary[n] || 0).positive? }

    fails << "SHARED bullet names a PR with no bullet of its own: #{l[0, 60]}"
  end

  (primary.keys + named).uniq.each do |n|
    pr = merged.find { |m| m[:num] == n }
    stale = pr && pr[:date] < horizon_start
    fails << "STALE ##{n} named but merged #{pr[:date]}" if stale
  end

  unreleased = lines.count { |l| l.start_with?("## Unreleased") }
  if unreleased.nonzero?
    fails << "#{unreleased} '## Unreleased' sections (the rule allows 0)"
  end
  sub = lines.count { |l| l.start_with?("### ") }
  fails << "#{sub} '###' subheadings (one bullet per PR: no subheadings)" if sub.nonzero?

  # A doc pointer must sit whole on one line: a wrapped pointer is not resolvable.
  docs = lines.flat_map { |l| l.scan(%r{doc/([a-z0-9_/]+\.md)}) }.flatten.uniq
  docs.each do |d|
    in_repo = File.exist?(File.join(doc_root, "doc", d))
    staged  = File.exist?(File.join(File.dirname(log_path), "doc", d))
    next if in_repo || staged || File.exist?(d)

    fails << "DANGLING doc pointer doc/#{d}"
  end
  long = lines.count { |l| l.length > MAX_LINE }
  fails << "#{long} lines over #{MAX_LINE} cols" if long.nonzero?
  fails
end

# History rules: date sections newest-first and unique; a new section may only be
# added at the top; the NEWEST previous section may be reworded (it can be
# partial); every older section must be byte-identical; a section may only be
# dropped once it is older than the horizon.
def history_fails(current, previous, horizon_start)
  fails = []
  cur_dates = current[:sections].map { |s| s[:date] }
  dupes = cur_dates.tally.select { |_d, c| c > 1 }.keys
  fails << "duplicate date sections: #{dupes.inspect}" if dupes.any?
  if cur_dates != cur_dates.sort.reverse
    fails << "sections not newest-first: #{cur_dates.inspect}"
  end

  prev_dates = previous[:sections].map { |s| s[:date] }
  newest_prev = prev_dates.max

  current[:sections].each do |s|
    old = previous[:sections].find { |p| p[:date] == s[:date] }
    if old.nil?
      if newest_prev && s[:date] < newest_prev
        fails << "NEW section #{s[:date]} below older history (newest-first broken)"
      end
      next
    end
    next if s[:date] == newest_prev

    next if old[:header] == s[:header] && old[:body] == s[:body]

    changed = s[:body].reject { |l| old[:body].include?(l) }
    changed = changed.first(3).map { |l| l[0, 50] }
    fails << "REWRITTEN old section #{s[:date]} (history is append-only; only " \
             "#{newest_prev} may change): #{changed.inspect}"
  end

  previous[:sections].each do |p|
    next if cur_dates.include?(p[:date])
    next if p[:date] < horizon_start

    fails << "REMOVED section #{p[:date]} while inside the horizon (>= #{horizon_start})"
  end
  fails
end

def report(log_path, parsed, merged, horizon_start, fails)
  horizon = horizon_of(merged, horizon_start)
  sections = parsed[:sections]
  bullets = sections.sum { |s| s[:body].count { |l| l.start_with?("- ") } }
  all = all_lines(parsed)
  puts "changelog: #{log_path} (#{all.size} lines, #{all.sum { |l| l.size + 1 }} bytes)"
  puts "horizon:   #{merged.size} merged PRs, #{horizon.size} in the horizon " \
       "(>= #{horizon_start}), #{merged.size - horizon.size} older"
  puts "sections:  #{sections.size} date sections, #{bullets} bullets, " \
       "newest #{sections.map { |s| s[:date] }.max.inspect}"
  real = sections.flat_map { |s| bullet_blocks(s[:body]).reject { |b| b[0].nil? } }
  puts "style:     max line #{(all.map(&:length).max || 0)} (limit #{MAX_LINE}), " \
       "max bullet #{(real.map(&:size).max || 0)} (limit #{MAX_BULLET_LINES})"
  fails.each { |f| puts "  FAIL #{f}" }
  puts(fails.empty? ? "RESULT: PASS" : "RESULT: FAIL (#{fails.size})")
end

def run(log_path, tsv_path, horizon_start, doc_root, previous_path)
  lines  = File.readlines(log_path)
  merged = parse_rows(tsv_path)
  parsed = parse_log(lines)
  fails  = shape_fails(parsed, merged, horizon_start, log_path, doc_root)
  if previous_path
    prev = parse_log(File.readlines(previous_path))
    fails.concat(history_fails(parsed, prev, horizon_start))
  else
    puts "history:   skipped (no --against; a bootstrap rewrite is allowed)"
  end
  report(log_path, parsed, merged, horizon_start, fails)
  fails.size
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.dup
  previous = nil
  if (i = args.index("--against"))
    previous = args[i + 1]
    args[i, 2] = []
  end
  log, tsv, horizon_start, doc_root = args
  usage = "usage: verify.rb <changelog> <merged_prs.tsv> <horizon> [doc_root] " \
          "[--against <previous changelog>]"
  abort(usage) if log.nil? || tsv.nil? || horizon_start.nil?
  abort("missing file: #{previous}") if previous && !File.file?(previous)

  exit(run(log, tsv, horizon_start, doc_root || ".", previous).zero? ? 0 : 1)
end
