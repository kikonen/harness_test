# frozen_string_literal: true

# Issue #346: file.search raises RegexpError for an invalid pattern instead of
# validating it.
# Run from the repo root: ruby analysis/346/repro.rb
# Expected before the fix: file.search('(') -> RegexpError: end pattern with unmatched parenthesis
# Expected after the fix:  the tool's OWN error string naming the pattern (no exception),
#                          and the same for a bad character class.
require "tmpdir"
require_relative "../../lib/tools/file_search_tool"

Dir.mktmpdir do |dir|
  fl = FileList.new([], workdir: dir)
  fl.add_dir(dir, :r)
  tool = Tools::FileSearchTool.new(fl)

  ["(", "[z-a]"].each do |pattern|
    result = begin
      tool.execute({ "pattern" => pattern })
    rescue StandardError => e
      "#{e.class}: #{e.message[0, 60]}"
    end
    puts "file.search(#{pattern.inspect}) -> #{result[0, 90]}"
  end
end
