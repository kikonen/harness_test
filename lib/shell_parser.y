class ShellParser < Racc::Parser

rule

  command : list
          { result = val[0] }

  list    : pipeline
           { result = [val[0]] }
          | list semi pipeline
           { result = val[0] + [val[2]] }
          | list and pipeline
           { result = val[0] + [val[2]] }
          | list or pipeline
           { result = val[0] + [val[2]] }

  pipeline : simple_command
            { result = [val[0]] }
           | pipeline pipe simple_command
            { result = val[0] + [val[2]] }
           | pipeline pipe_and simple_command
            { result = val[0] + [val[2]] }

  simple_command : word
                  { result = [val[0]] }
                 | simple_command word
                  { result = val[0] + [val[1]] }

end
----header
require_relative 'shell_tokenizer'
----inner
ParseError = Class.new(StandardError)

# Parse a shell command string into an array of segment strings.
# Each segment is a "simple command" (a sequence of words).
# Raises ParseError for unsafe constructs (redirects, substitutions, etc.)
def self.parse(command)
  new(command).parse!
end

def initialize(command)
  @tokens = ShellTokenizer.tokenize(command.to_s)
  @pos    = 0
end

# Parse and return an array of command segment strings.
# e.g. "ls | grep x" => ["ls", "grep x"]
#      "echo hi && pwd" => ["echo hi", "pwd"]
def parse!
  raise ParseError, "empty command" if @tokens.empty?
  tree = do_parse
  # tree is [[["ls"], ["grep", "x"]], ...] (list of pipelines of simple_commands)
  # Flatten to segment strings: each simple_command's words joined by space.
  tree.flatten(1).map { |words| words.join(' ') }
end

def next_token
  return [false, nil] if @pos >= @tokens.length

  kind, text = @tokens[@pos]
  @pos += 1

  case kind
  when :word     then [:word, text]
  when :pipe     then [:pipe, nil]
  when :and      then [:and, nil]
  when :or       then [:or, nil]
  when :semi     then [:semi, nil]
  when :pipe_and then [:pipe_and, nil]
  when :danger   then raise ParseError, "unsafe construct: #{text}"
  else raise ParseError, "unknown token kind: #{kind}"
  end
end

def error_token(token, value, lvalue)
  raise ParseError, "unexpected token near: #{token.inspect}"
end

def unexpected_token(token, value, vstack)
  raise ParseError, "syntax error at: #{token.inspect}"
end
