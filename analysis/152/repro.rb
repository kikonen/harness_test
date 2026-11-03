# frozen_string_literal: true

# Issue #152: file.search / file.list derive the base directory to ask READ on
# by regex-stripping the GLOB STRING, so a brace (or bracket) glob names a
# directory that does not exist and the grant dialog asks for that bogus path:
#   '{README.md,lib/commands/*}'  ->  base dir '{README.md,lib/commands'
#
# Legacy.base is the pre-fix derivation copied verbatim; FileList#glob_base_dir
# is the replacement. Nothing is granted or prompted here - the script only
# DERIVES paths, so it runs from a fresh clone with no local state:
#   ruby analysis/152/repro.rb
require "tmpdir"

require_relative "../../lib/file_list"

module Legacy
  # The two lines file_search_tool.rb / file_list_tool.rb used.
  def self.base(expanded)
    stripped = expanded.sub(%r{/\*\*?/.*\z}, "").sub(%r{/\*\*?\z}, "")
    stripped != expanded ? stripped : File.dirname(stripped)
  end
end

PATTERNS = [
  "lib/**/*.rb", "lib/*.rb", "lib/a.rb", "lib", ".", "**/*",
  "lib/{a,b}/*.rb", "{README.md,lib/commands/*}", "analysis/[0-9]*/repro.rb",
  "{lib,spec}/**/*", "lib/tools/{file_*,git_*}.rb", "../*"
].freeze

ROW = "%-32s %-30s %-24s %s"

Dir.mktmpdir do |dir|
  %w[lib lib/commands lib/tools spec analysis/152].each do |sub|
    FileUtils.mkdir_p(File.join(dir, sub))
  end
  File.write(File.join(dir, "README.md"), "x\n")
  File.write(File.join(dir, "lib/commands/clear_command.rb"), "x\n")
  File.write(File.join(dir, "lib/tools/file_search_tool.rb"), "x\n")
  File.write(File.join(dir, "spec/a_spec.rb"), "x\n")

  list = FileList.new([], workdir: dir)

  def shown(list, path)
    list.display_path(path)
  end

  puts "workdir: #{shown(list, dir)}"
  PATTERNS.each do |pattern|
    expanded = File.expand_path(pattern, dir)
    legacy   = shown(list, Legacy.base(expanded))
    fresh    = shown(list, list.glob_base_dir(pattern))
    flag     = legacy == fresh ? "" : "->"
    puts format(ROW, pattern, legacy, fresh, flag)
  end

  brace = "{README.md,lib/commands/*}"
  bogus = shown(list, Legacy.base(File.expand_path(brace, dir)))
  real  = shown(list, list.glob_base_dir(brace))
  puts
  puts "The bogus ask, on the pattern from the issue report:"
  puts "  legacy asked for #{bogus.inspect} - exists: #{File.exist?(bogus)}"
  puts "  now asked for #{real.inspect} - exists: #{File.exist?(real)}"

  puts
  puts "A pattern that IS a directory no longer asks for its parent:"
  puts "  legacy for 'lib': #{shown(list, Legacy.base(File.expand_path('lib', dir)))}"
  puts "  now: #{shown(list, list.glob_base_dir('lib'))}"

  outside  = Legacy.base(File.expand_path(".", dir))
  external = list.within_workdir?(outside) ? "yes" : "NO"
  puts
  puts "Pattern '.' (the whole project) must not reach outside the workdir:"
  puts "  legacy asked for #{shown(list, outside)} - inside workdir: #{external}"
  own = list.glob_base_dir(".")
  inside = list.within_workdir?(own) ? "yes" : "NO"
  puts "  now asked for #{shown(list, own)} - inside workdir: #{inside}"
end
