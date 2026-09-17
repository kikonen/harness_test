#!/usr/bin/env ruby
# frozen_string_literal: true
#
# harness.rb — one-shot AI edit harness. Any OpenAI-compatible server.
# No agent loop, no tool calling. Prompt in, edited files out.
#
# Usage:
#   ruby harness.rb -m qwen2.5-coder:32b -f src/app.py -f src/utils.py "add input validation"
#   ruby harness.rb -m my-model --base-url http://192.168.1.10:8000/v1 \
#                    --token sk-abc123 -f main.py "refactor"
#   HARNESS_TOKEN=sk-abc123 ruby harness.rb -m gpt-4o -f config.rb "use env vars"

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'optparse'
require 'debug'

SYSTEM_PROMPT = <<~'TEXT'
  You are a precise code editor. You receive file contents and an instruction.
  Return ONLY the modified files in this exact format:

  === FILE: <relative/path> ===
  <complete file content>
  === END ===

  Rules:
  - Only return files that changed.
  - Each file must be complete (not a diff, not a snippet).
  - No commentary before or after the blocks.
  - Preserve original formatting, indentation, and style.
TEXT

def build_user_prompt(files, instruction)
  sections = files.map do |path, content|
    "--- FILE: #{path} ---\n#{content}--- END ---\n"
  end
  "## Files\n\n#{sections.join("\n")}\n## Instruction\n\n#{instruction}\n"
end

def parse_response(text)
  files = {}
  text.scan(/=== FILE: (.+?) ===\n(.*?)\n?=== END ===/m) do |path, content|
    files[path.strip] = content.rstrip
  end
  files
end

def call_llm(base_url, model, system, user, auth_token: nil, timeout: 300)
  uri  = URI("#{base_url}/chat/completions")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl     = (uri.scheme == 'https')
  http.open_timeout = 30
  http.read_timeout = timeout

  req = Net::HTTP::Post.new(uri.request_uri)
  req['Content-Type'] = 'application/json'
  req['Authorization'] = "Bearer #{auth_token}" if auth_token
  req.body = JSON.generate(
    model: model,
    messages: [
      { role: 'system', content: system },
      { role: 'user',   content: user   }
    ],
    temperature: 0.1,
    max_tokens: 8192
  )

  resp = http.request(req)
  abort "LLM error (HTTP #{resp.code}):\n#{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

  JSON.parse(resp.body)['choices'][0]['message']['content']
end

# ── CLI ──────────────────────────────────────────────────────────────────

options = { files: [] }

parser = OptionParser.new do |o|
  o.banner  = 'Usage: harness.rb [options] <instruction>'
  o.separator ''
  o.on('-m MODEL', '--model MODEL', 'Model name (required)')                 { |v| options[:model]    = v }
  o.on('-f FILE',  '--file FILE',  'Context file, repeatable')               { |v| options[:files]  << v }
  o.on('--base-url URL', 'API base URL [default: http://localhost:11434/v1]') { |v| options[:base_url] = v }
  o.on('--token TOKEN',  'Bearer auth token [or $HARNESS_TOKEN]')            { |v| options[:token]    = v }
  o.on('--system TEXT',  'Override system prompt')                           { |v| options[:system]   = v }
  o.on('--dry-run',      'Print edits, do not write files')                  { options[:dry_run]  = true }
  o.on('-v', '--verbose', 'Show full prompt and raw response')               { options[:verbose]  = true }
  o.on('-h', '--help')                                                        { puts o; exit }
end
parser.parse!

options[:base_url] ||= ENV['HARNESS_BASE_URL']
options[:model] ||= ENV['HARNESS_MODEL']
options[:system]   ||= SYSTEM_PROMPT
options[:token]    ||= ENV['HARNESS_TOKEN']

instruction = ARGV.join(' ')
abort 'error: instruction required'           if instruction.empty?
abort 'error: -m / --model is required'       unless options[:model]
abort 'error: at least one -f / --file needed' unless options[:files].any?

#debugger

# ── Run ──────────────────────────────────────────────────────────────────

files = {}
options[:files].each do |f|
  abort "error: not found: #{f}" unless File.file?(f)
  files[f] = File.read(f)
end

user_prompt = build_user_prompt(files, instruction)

if options[:verbose]
  puts "─── system ───\n#{options[:system]}"
  puts "─── user ───\n#{user_prompt}"
  puts "─── #{options[:model]} @ #{options[:base_url]} ───\n"
end

text = call_llm(
  options[:base_url], options[:model], options[:system], user_prompt,
  auth_token: options[:token]
)

if options[:verbose]
  puts "─── response ───\n#{text}\n"
end

parsed = parse_response(text)
if parsed.empty?
  warn 'no file blocks detected — raw response:'
  warn text
  exit 1
end

parsed.each do |path, content|
  if options[:dry_run]
    puts "─── DRY RUN: #{path} (#{content.length} chars) ───"
    puts content
  else
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir) unless dir == '.'
    File.write(path, content + "\n")
    puts "wrote #{path}"
  end
end

puts "\n→ git diff" unless options[:dry_run]
