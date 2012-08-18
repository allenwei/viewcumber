require 'cucumber'
require 'capybara'
require 'digest/sha1'

require 'cucumber/formatter/json'
require 'console'
require 'fileutils'

if respond_to? :AfterStep
  Before do
    if Capybara.current_driver == :webkit
      page.driver.resize_window(1280, 1024)
    else
      page.driver.browser.manage.window.maximize
    end
  end
  AfterStep do |scenario|
    begin
      if !@email.blank?
        Viewcumber.last_step_html = Viewcumber.rewrite_css_and_image_references(@email)
        @email = nil
      else
        filename = Time.now.to_i.to_s + "_" + Array.new(5) { rand(9) }.join + ".png"
        full_path = File.join(File.expand_path("viewcumber"), 'screenshots', filename)
        if Capybara.current_driver == :webkit
          page.driver.render full_path
        else
          page.driver.browser.save_screenshot(full_path)
        end
        Viewcumber.last_step_html = <<-EOF
        <html>
          <body>
            <img src="../screenshots/#{filename}">
          </body>
        </html>
        EOF
      end
    rescue Exception => e
    end
  end
end

class Viewcumber < Cucumber::Formatter::Json
  include Console
  attr_accessor :step_mother

  module GherkinObjectAttrs
    def feature_hash
      @feature_hash
    end

    def feature_hashes
      @feature_hashes
    end
  end

  class << self
    attr_accessor :last_step_html

    def rewrite_css_and_image_references(response_html) # :nodoc:
      return response_html unless Capybara.asset_root
      directories = Dir.new(Capybara.asset_root).entries.inject([]) do |list, name|
        list << name if File.directory?(File.join(Capybara.asset_root, name)) and not name.to_s =~ /^\./
        list
      end
      response_html.gsub!(/("|')\/(#{directories.join('|')})/, '\1public/\2')
      response_html.gsub(/("|')http:\/\/.*\/images/, '\1public/images')
    end
  end

  def initialize(step_mother, path_or_io, options)
    make_output_dir
    copy_app
    copy_public_folder
    @step_mother, @options = step_mother, options
    super(step_mother, File.open(results_filename, 'w+'), options)
    @gf.extend GherkinObjectAttrs
  end

  def after_step(step)

    additional_step_info = { 'html_file' => write_html_to_file(Viewcumber.last_step_html),
                             'emails' => emails_for_step(step) }

    current_element = @gf.feature_hash['elements'].last
    current_step = current_element['steps'].last
    current_step.merge!(additional_step_info)
  end

  def scenario_name(keyword, name, file_colon_line, source_indent)
    print_feature_element_name(keyword, name, file_colon_line, source_indent)
  end

  # The JSON formatter adds the background as a feature element,
  # we only want full scenarios so lets delete all with type 'background'
  def after_feature(feature)
    # this might want to be feature_hashes and an each
    if @gf.feature_hash && @gf.feature_hash['elements']
      @gf.feature_hash['elements'].delete_if do |element|
        element['type'] == 'background'
      end
    end
    super(feature)
  end

  def after_features(features)
    print_summary(features)
    super(features)
  end

  def step_name(keyword, step_match, status, source_indent, background, file_colon_line)
    name_to_report = format_step(keyword, step_match, status, source_indent)
    STDOUT.puts name_to_report
  end


  def after_step_result(keyword, step_match, multiline_arg, status, exception, source_indent, background, file_colon_line)
    STDOUT.puts multiline_arg
    @status = status
  end

  def exception(exception, status)
    @exception_raised = true
    print_exception(exception, status, 0)
  end

  private

  def print_summary(features)
    print_steps(:pending)
    print_steps(:failed)
    print_stats(features, @options)
    print_snippets(@options)
    print_passing_wip(@options)
  end

  private
  def print_feature_element_name(keyword, name, file_colon_line, source_indent)
    STDOUT.puts if @scenario_indent == 6
    names = name.empty? ? [name] : name.split("\n")
    line = "#{keyword}: #{names[0]}"
    STDOUT.print(line)
    if @options[:source]
      line_comment = " # #{file_colon_line}"
      STDOUT.print(format_string(line_comment, :comment))
    end
    STDOUT.puts
    names[1..-1].each {|s| STDOUT.puts "    #{s}"}
    STDOUT.flush
  end


  # Writes the given html to a file in the results directory
  # and returns the filename.
  #
  # Filename are based on the SHA1 of the contents. This means
  # that we will only write the same html once
  def write_html_to_file(html)
    return nil unless html && html != ""
    filename = Digest::SHA1.hexdigest(html) + ".html"
    full_file_path = File.join(results_dir, filename)

    unless File.exists?(full_file_path)
      File.open(full_file_path, 'w+') do |f|
        f  << html
      end
    end

    filename
  end

  def emails_for_step(step)
    ActionMailer::Base.deliveries.collect{|mail| mail_as_json(mail) }
  end

  def mail_as_json(mail)
    html_filename = write_email_to_file('text/html', mail)
    text_filename = write_email_to_file('text/plain', mail)
    {
      :to => mail.to,
      :from => mail.from,
      :subject => mail.subject,
      :body => {
        :html => html_filename,
        :text => text_filename
      }
    }
  end

  # Writes the content of the given content type to disk and returns
  # the filename to access it.
  #
  # Returns nil if no file was written.
  def write_email_to_file(content_type, mail)
    mail_part = mail.parts.find{|part| part.content_type.to_s.include? content_type }
    return nil unless mail_part

    contents = mail_part.body.to_s
    filename = Digest::SHA1.hexdigest(contents) + content_type.gsub('/', '.') + ".email.html"

    full_file_path = File.join(results_dir, filename)
    unless File.exists?(full_file_path)
      File.open(full_file_path, 'w+') do |f|
        f << prepare_email_content(content_type, contents)
      end
    end

    filename
  end

  def prepare_email_content(content_type, contents)
    case content_type
    when 'text/html'
      Viewcumber.rewrite_css_and_image_references(contents)
    when 'text/plain'
      "<html><body><pre>#{contents}</pre></body></html>"
    else
      contents
    end
  end

  def results_filename
    @json_file ||= File.join(output_dir, 'results.json')
  end

  def results_dir
    @results_dir ||= File.join(output_dir, "results")
  end

  def output_dir
    @output_dir ||= File.expand_path("viewcumber")
  end

  def screenshots_dir
    @screenshots_dir ||= File.join(output_dir, "screenshots")
  end

  def make_output_dir
    FileUtils.mkdir output_dir unless File.directory? output_dir
    FileUtils.mkdir results_dir unless File.directory? results_dir
    FileUtils.mkdir screenshots_dir unless File.directory? screenshots_dir
  end

  def copy_app
    app_dir = File.expand_path(File.join('..', '..', 'build'), __FILE__)
    FileUtils.cp_r "#{app_dir}/.", output_dir
  end

  def copy_public_folder
    FileUtils.cp_r File.join(Rails.root, "public"), File.join(results_dir, "public")
  end

end
