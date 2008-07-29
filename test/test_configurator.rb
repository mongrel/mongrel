# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html 
# for more information.
Dir.chdir(File.dirname(__FILE__) + "/../")
require 'test/testhelp'

$test_plugin_fired = 0

class TestPlugin < GemPlugin::Plugin "/handlers"
  include Mongrel::HttpHandlerPlugin

  def process(request, response)
    $test_plugin_fired += 1
  end
end


class Sentinel < GemPlugin::Plugin "/handlers"
  include Mongrel::HttpHandlerPlugin

  def process(request, response)
    raise "This Sentinel plugin shouldn't run."
  end
end


class ConfiguratorTest < Test::Unit::TestCase

  def test_base_handler_config
    @config = nil

    redirect_test_io do
      @config = Mongrel::Configurator.new :host => "localhost" do
        listener :port => 4501 do
          # 2 in front should run, but the sentinel shouldn't since dirhandler processes the request
          uri "/", :handler => plugin("/handlers/testplugin")
          uri "/", :handler => plugin("/handlers/testplugin")
          uri "/", :handler => Mongrel::DirHandler.new(".")
          uri "/", :handler => plugin("/handlers/testplugin")

          uri "/test", :handler => plugin("/handlers/testplugin")
          uri "/test", :handler => plugin("/handlers/testplugin")
          uri "/test", :handler => Mongrel::DirHandler.new(".")
          uri "/test", :handler => plugin("/handlers/testplugin")

          debug "/"
          setup_signals

          run_config(File.dirname(__FILE__) + "/../test/mongrel.conf")
          load_mime_map(File.dirname(__FILE__) + "/../test/mime.yaml")

          run
        end
      end
    end

    # pp @config.listeners.values.first.classifier.routes

    @config.listeners.each do |host,listener| 
      assert listener.classifier.uris.length == 3, "Wrong number of registered URIs"
      assert listener.classifier.uris.include?("/"),  "/ not registered"
      assert listener.classifier.uris.include?("/test"), "/test not registered"
    end

    res = Net::HTTP.get(URI.parse('http://localhost:4501/test'))
    assert res != nil, "Didn't get a response"
    assert $test_plugin_fired == 3, "Test filter plugin didn't run 3 times."

    redirect_test_io do
      res = Net::HTTP.get(URI.parse('http://localhost:4501/'))

      assert res != nil, "Didn't get a response"
      assert $test_plugin_fired == 6, "Test filter plugin didn't run 6 times."
    end

    redirect_test_io do
      @config.stop(false, true)
    end

    assert_raise Errno::EBADF, Errno::ECONNREFUSED do
      res = Net::HTTP.get(URI.parse("http://localhost:4501/"))
    end
  end
  
  def test_pid_file_removal__file_renamed__should_find_my_pid_file
    return if RUBY_PLATFORM =~ /mswin/
    
    @pid_file = File.dirname(__FILE__) + "/mongrel_test.pid"
    @config = Mongrel::Configurator.new :host => "localhost", :pid_file => @pid_file do
      @pid_file = defaults[:pid_file]
      write_pid_file
      File.rename(@pid_file, @pid_file.gsub(".pid", ".deprecated.pid"))
      File.open(@pid_file, "w")  {|f| f << "BOGUSPID" }
      remove_pid_file
    end
    
    assert ! File.exist?(@pid_file.gsub(".pid", ".deprecated.pid"))
    assert_equal "BOGUSPID", File.read(@pid_file)
    File.delete(@pid_file)
  end
end
