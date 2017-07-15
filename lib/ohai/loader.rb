#
# Author:: Claire McQuin (<claire@chef.io>)
# Copyright:: Copyright (c) 2013-2016 Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef-config/path_helper"
require "ohai/log"
require "ohai/mash"
require "ohai/dsl"
require "pathname"

module Ohai

  # Ohai plugin loader. Finds all the plugins in your
  # `Ohai.config[:plugin_path]` (supports a single or multiple path setting
  # here), evaluates them and returns plugin objects.
  class Loader

    # Simple struct like objects to track the path of a plugin and the root
    # directory of plugins in which we found it.
    PluginFile = Struct.new(:path, :plugin_root) do

      # Finds all the *.rb files under the configured paths in :plugin_path
      def self.find_all_in(plugin_dir)
        unless Dir.exist?(plugin_dir)
          Ohai::Log.info("The plugin path #{plugin_dir} does not exist. Skipping...")
          return []
        end

        Ohai::Log.debug("Searching for Ohai plugins in #{plugin_dir}")

        escaped = ChefConfig::PathHelper.escape_glob_dir(plugin_dir)
        Dir[File.join(escaped, "**", "*.rb")].map do |file|
          new(file, plugin_dir)
        end
      end
    end

    def initialize(controller)
      @controller = controller
      @v7_plugin_classes = []
    end

    # Searches all plugin paths and returns an Array of PluginFile objects
    # representing each plugin file.
    def plugin_files_by_dir(dir = Ohai.config[:plugin_path])
      Array(dir).inject([]) do |plugin_files, plugin_path|
        plugin_files + PluginFile.find_all_in(plugin_path)
      end
    end

    def load_all
      plugin_files_by_dir.each do |plugin_file|
        load_plugin_file(plugin_file.path)
      end

      collect_v7_plugins
    end

    def load_additional(from)
      from = [ Ohai.config[:plugin_path], from].flatten
      plugin_files_by_dir(from).collect do |plugin_file|
        Ohai::Log.debug "Loading additional plugin: #{plugin_file}"
        plugin = load_plugin_file(plugin_file.path)
        load_v7_plugin(plugin)
      end
    end

    # Load a specified file as an ohai plugin and creates an instance of it.
    # Not used by ohai itself, but can be used to load a plugin for testing
    # purposes.
    def load_plugin(plugin_path)
      plugin_class = load_plugin_file(plugin_path)
      return nil unless plugin_class.kind_of?(Class)
      case
      when plugin_class < Ohai::DSL::Plugin::VersionVII
        load_v7_plugin(plugin_class)
      else
        raise Exceptions::IllegalPluginDefinition, "cannot create plugin of type #{plugin_class}"
      end
    end

    # Reads the file specified by `plugin_path` and returns a class object for
    # the ohai plugin defined therein.
    def load_plugin_file(plugin_path)
      # Read the contents of the plugin
      contents = ""
      begin
        Ohai::Log.debug("Reading plugin at #{plugin_path}")
        contents << IO.read(plugin_path)
      rescue IOError, Errno::ENOENT
        Ohai::Log.warn("Unable to open or read plugin at #{plugin_path}")
        return nil
      end

      if contents.include?("Ohai.plugin")
        load_v7_plugin_class(contents, plugin_path)
      end
    end

    private

    def collect_provides(plugin)
      plugin_provides = plugin.class.provides_attrs
      @controller.provides_map.set_providers_for(plugin, plugin_provides)
    end

    def collect_v7_plugins
      @v7_plugin_classes.each do |plugin_class|
        load_v7_plugin(plugin_class)
      end
    end

    def load_v7_plugin_class(contents, plugin_path)
      Ohai::Log.debug("Loading Ohai plugin class from #{plugin_path}")
      plugin_class = eval(contents, TOPLEVEL_BINDING, plugin_path)
      unless plugin_class.kind_of?(Class) && plugin_class < Ohai::DSL::Plugin
        raise Ohai::Exceptions::IllegalPluginDefinition, "Plugin file cannot contain any statements after the plugin definition"
      end
      plugin_class.sources << plugin_path
      @v7_plugin_classes << plugin_class unless @v7_plugin_classes.include?(plugin_class)
      plugin_class
    rescue SystemExit, Interrupt
      raise
    rescue Ohai::Exceptions::InvalidPluginName => e
      Ohai::Log.warn("Plugin Name Error: <#{plugin_path}>: #{e.message}")
    rescue Ohai::Exceptions::IllegalPluginDefinition => e
      Ohai::Log.warn("Plugin Definition Error: <#{plugin_path}>: #{e.message}")
    rescue NoMethodError => e
      Ohai::Log.warn("Plugin Method Error: <#{plugin_path}>: unsupported operation \'#{e.name}\'")
    rescue SyntaxError => e
      # split on occurrences of
      #    <env>: syntax error,
      #    <env>:##: syntax error,
      # to remove from error message
      parts = e.message.split(/<.*>[:[0-9]+]*: syntax error, /)
      parts.each do |part|
        next if part.length == 0
        Ohai::Log.warn("Plugin Syntax Error: <#{plugin_path}>: #{part}")
      end
    rescue Exception, Errno::ENOENT => e
      Ohai::Log.warn("Plugin Error: <#{plugin_path}>: #{e.message}")
      Ohai::Log.debug("Plugin Error: <#{plugin_path}>: #{e.inspect}, #{e.backtrace.join('\n')}")
    end

    def load_v7_plugin(plugin_class)
      plugin = plugin_class.new(@controller.data)
      collect_provides(plugin)
      plugin
    end

  end
end
