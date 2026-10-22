# frozen_string_literal: true
# Issue #346: file.search raises RegexpError for an invalid pattern instead of
# validating it.
# Run from the repo root: ruby analysis/346/repro.rb
# Expected: file.search('(') -> RegexpError: end pattern with unmatched parenthesis: /(/
require "tmpdir"
require_relative "../../lib/tools/file_search_tool"

Dir.mktmpdir do |dir|
  fl = FileList.new([], workdir: dir)
  fl.add_dir(dir, :r)
  begin
    Tools::FileSearchTool.new(fl).execute({ "pattern" => "(" })
    puts "no raise?!"
  rescue StandardError => e
    puts "file.search('(') -> #{e.class}: #{e.message[0, 60]}"
  end
end
