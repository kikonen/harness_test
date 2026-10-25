# frozen_string_literal: true

# Issue #290 follow-up: why the symlink example of dir_delete_tool_spec used to
# skip on Windows, and what a link fixture there really is. Run from the repo
# root: ruby analysis/290/repro.rb
#
# Measured on the owner's Windows box (ruby 4.0.7 x64-mingw-ucrt, developer mode
# OFF, where File.symlink raises EACCES) and on CI ubuntu-latest (real symlinks).
require "tmpdir"
require "fileutils"
require_relative "../../lib/file_list"
require_relative "../../lib/tools/dir_delete_tool"

def native(path)
  path.tr("/", "\\")
end

def junction(link, target)
  system(
    "cmd",
    "/c",
    "mklink",
    "/J",
    native(link),
    native(target),
    out: File::NULL,
    err: File::NULL)
end

def report(label, path)
  puts format(
    "%s -> symlink?=%s lstat.ftype=%s directory?=%s",
    label,
    File.symlink?(path),
    (File.lstat(path).ftype rescue "n/a"),
    File.directory?(path))
end

# The fixture the spec builds: a real symlink where the box allows one, else an
# NTFS junction (no privilege needed).
def make_link(link, target)
  File.symlink(target, link)
  "symlink"
rescue SystemCallError
  junction(link, target) ? "junction" : nil
end

Dir.mktmpdir do |dir|
  target = File.join(dir, "keep")
  link   = File.join(dir, "link")
  FileUtils.mkdir_p(target)
  File.write(File.join(target, "inside.txt"), "keep me")

  # 1. A real symlink needs the SeCreateSymbolicLink privilege (developer mode).
  begin
    File.symlink(target, link)
    puts "File.symlink             -> created"
  rescue SystemCallError => e
    puts "File.symlink             -> #{e.class}: #{e.message.split(": ").last}"
  end

  # 2. A junction (mklink /J) is a reparse point: no privilege needed, and Ruby
  #    reports it as a LINK - while File.directory? still follows it, which is
  #    why the tool checks the link predicate FIRST.
  kind = make_link(link, target)
  puts "fixture kind             -> #{kind.inspect}"
  report("link", link) if kind

  # 3. Unlinking the link leaves the target's tree standing.
  if kind
    File.delete(link)
    inside = File.join(target, "inside.txt")
    puts "after unlinking the link -> target dir=#{File.directory?(target)} " \
      "inside=#{File.exist?(inside)}"
  end

  # 4. A link INSIDE a tree is unlinked as a leaf; the tool never walks into it.
  tree = File.join(dir, "tree")
  FileUtils.mkdir_p(File.join(tree, "sub"))
  File.write(File.join(tree, "a.txt"), "a")
  inner = File.join(tree, "sub", "inner")
  if make_link(inner, target)
    list = FileList.new(workdir: dir)
    list.add_dir("tree", :d)
    tool = Tools::DirDeleteTool.new(list, session: nil, harness: nil)
    out  = tool.execute("path" => "tree")
    puts "link inside a tree       -> #{out[0, 58]} tree gone=#{!File.exist?(tree)} " \
      "target survived=#{File.exist?(File.join(target, "inside.txt"))}"
  end
end
