require 'cucumber/formatter/ansicolor'
require 'cucumber/formatter/duration'
require 'cucumber/formatter/summary'
require 'cucumber/errors'

# This module contains helper methods that are used by formatters
# that print output to the terminal.
module Console
  extend Cucumber::Formatter::ANSIColor
  include Cucumber::Formatter::Duration
  include Cucumber::Formatter::Summary

  FORMATS = Hash.new{|hash, format| hash[format] = method(format).to_proc}

  def format_step(keyword, step_match, status, source_indent)
    comment = if source_indent
                c = (' # ' + step_match.file_colon_line).indent(source_indent)
                format_string(c, :comment)
              else
                ''
              end

    format = format_for(status, :param)
    line = keyword + step_match.format_args(format) + comment
    format_string(line, status)
  end

  def format_string(o, status)
    fmt = format_for(status)
    o.to_s.split("\n").map do |line|
      if Proc === fmt
        fmt.call(line)
      else
        fmt % line
      end
    end.join("\n")
  end

  def print_steps(status)
    print_elements(step_mother.steps(status), status, 'steps')
  end

  def print_elements(elements, status, kind)
    if elements.any?
      STDOUT.puts(format_string("(::) #{status} #{kind} (::)", status))
      STDOUT.puts
      STDOUT.flush
    end

    elements.each_with_index do |element, i|
      if status == :failed
        print_exception(element.exception, status, 0)
      else
        STDOUT.puts(format_string(element.backtrace_line, status))
      end
      STDOUT.puts
      STDOUT.flush
    end
  end

  def print_stats(features, options)
    @failures = step_mother.scenarios(:failed).select { |s| s.is_a?(Cucumber::Ast::Scenario) || s.is_a?(Cucumber::Ast::OutlineTable::ExampleRow) }
    @failures.collect! { |s| (s.is_a?(Cucumber::Ast::OutlineTable::ExampleRow)) ? s.scenario_outline : s }

    if !@failures.empty?
      STDOUT.puts format_string("Failing Scenarios:", :failed)
      @failures.each do |failure|
        profiles_string = options.custom_profiles.empty? ? '' : (options.custom_profiles.map{|profile| "-p #{profile}" }).join(' ') + ' '
        source = options[:source] ? format_string(" # Scenario: " + failure.name, :comment) : ''
        STDOUT.puts format_string("cucumber #{profiles_string}" + failure.file_colon_line, :failed) + source
      end
      STDOUT.puts
    end

    STDOUT.puts scenario_summary(step_mother) {|status_count, status| format_string(status_count, status)}
    STDOUT.puts step_summary(step_mother) {|status_count, status| format_string(status_count, status)}

    STDOUT.puts(format_duration(features.duration)) if features && features.duration

    STDOUT.flush
  end

  def print_exception(e, status, indent)
    message = "#{e.message} (#{e.class})"
    if ENV['CUCUMBER_TRUNCATE_OUTPUT']
      message = linebreaks(message, ENV['CUCUMBER_TRUNCATE_OUTPUT'].to_i)
    end

    string = "#{message}\n#{e.backtrace.join("\n")}".indent(indent)
    STDOUT.puts(format_string(string, status))
  end

  # http://blade.nagaokaut.ac.jp/cgi-bin/scat.rb/ruby/ruby-talk/10655
  def linebreaks(s, max)
    s.gsub(/.{1,#{max}}(?:\s|\Z)/){($& + 5.chr).gsub(/\n\005/,"\n").gsub(/\005/,"\n")}.rstrip
  end

  def print_snippets(options)
    return unless options[:snippets]
    undefined = step_mother.steps(:undefined)
    return if undefined.empty?

    unknown_programming_language = step_mother.unknown_programming_language?
    snippets = undefined.map do |step|
      step_name = Cucumber::Undefined === step.exception ? step.exception.step_name : step.name
      step_multiline_class = step.multiline_arg ? step.multiline_arg.class : nil
      snippet = @step_mother.snippet_text(step.actual_keyword, step_name, step_multiline_class)
      snippet
    end.compact.uniq

    text = "\nYou can implement step definitions for undefined steps with these snippets:\n\n"
    text += snippets.join("\n\n")
    STDOUT.puts format_string(text, :undefined)

    if unknown_programming_language
      STDOUT.puts format_string("\nIf you want snippets in a different programming language,\n" +
                                "just make sure a file with the appropriate file extension\n" +
                                "exists where cucumber looks for step definitions.", :failed)
    end

    STDOUT.puts
    STDOUT.flush
  end

  def print_passing_wip(options)
    return unless options[:wip]
    passed = step_mother.scenarios(:passed)
    if passed.any?
      STDOUT.puts format_string("\nThe --wip switch was used, so I didn't expect anything to pass. These scenarios passed:", :failed)
      print_elements(passed, :passed, "scenarios")
    else
      STDOUT.puts format_string("\nThe --wip switch was used, so the failures were expected. All is good.\n", :passed)
    end
  end

  def embed(file, mime_type, label)
    # no-op
  end

  #define @delayed_messages = [] in your Formatter if you want to
  #activate this feature
  def puts(*messages)
    if @delayed_messages
      @delayed_messages += messages
    else
      if STDOUT
        STDOUT.puts
        messages.each do |message|
          STDOUT.puts(format_string(message, :tag))
        end
        STDOUT.flush
      end
    end
  end

  def print_messages
    @delayed_messages.each {|message| print_message(message)}
    empty_messages
  end

  def print_table_row_messages
    return if @delayed_messages.empty?
    STDOUT.print(format_string(@delayed_messages.join(', '), :tag).indent(2))
    STDOUT.flush
    empty_messages
  end

  def print_message(message)
    STDOUT.puts(format_string(message, :tag).indent(@indent))
    STDOUT.flush
  end

  def empty_messages
    @delayed_messages = []
  end

  private

  def format_for(*keys)
    key = keys.join('_').to_sym
    fmt = FORMATS[key]
    raise "No format for #{key.inspect}: #{FORMATS.inspect}" if fmt.nil?
    fmt
  end
end
