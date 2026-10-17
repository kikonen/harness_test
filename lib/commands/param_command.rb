# frozen_string_literal: true

require_relative "../command"

module Commands
  # /param - show and adjust the LLM parameters for this session (issue #219).
  #
  #   /param                     list every parameter (effective value +
  #                              override/default source)
  #   /param <key>               show one parameter
  #   /param <key> <value>       set a session-level override
  #   /param <key> default       reset one back to the profile (config) value
  #
  # Values: 'off' (reasoning_effort: use the server default / no reasoning),
  # 'default' (reset), or a number/word parsed to the parameter's type.
  class ParamCommand < Command
    def handle(args)
      args  = args.strip
      words = args.split(/\s+/).reject(&:empty?)

      case words.size
      when 0 then list_all
      when 1 then show_one(words[0])
      when 2 then set_one(words[0], words[1])
      else
        usage
      end
    end

    private

    def list_all
      param.list_display.each { |line| @ui.puts line }
    end

    def show_one(key)
      unless param.overrideable?(key)
        @ui.puts "Unknown parameter '#{key}'. Adjustable: #{param.keys.join(', ')}"
        return
      end

      eff  = param.effective(key)
      mark = param.overridden?(key) ? "session override" : "profile default"
      @ui.puts "#{key}: #{param.display_value(eff)} (#{mark})"
    end

    def set_one(key, value)
      @ui.puts param.set(key, value)
    end

    def usage
      @ui.puts 'usage: /param [<key> <value>]   (value: a number/word, "off", or "default")'
    end

    # The shared override object (SessionManager owns the single instance).
    def param
      @harness.session_manager.param_overrides
    end
  end
end
