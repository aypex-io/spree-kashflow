# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Rails engine for the KashFlow integration.
    #
    # Loads the gem's +app/+ tree into the host application and applies the
    # gem's single decorator on each reload.
    #
    class Engine < ::Rails::Engine
      require "spree/core"
      isolate_namespace Spree

      # Deliberately not "spree-kashflow": engine_name generates route helper
      # prefixes and must be a valid Ruby identifier, so it cannot contain a dash.
      engine_name "spree_kashflow"

      config.generators do |g|
        g.test_framework :rspec
      end

      ##
      # Loads the gem's decorators. Called on every reload in development.
      #
      # @return [void]
      #
      def self.activate
        # Three levels up from lib/spree/kashflow/ to reach the gem root.
        Dir.glob(File.join(File.dirname(__FILE__), "../../../app/**/*_decorator*.rb")).sort.each do |c|
          Rails.configuration.cache_classes ? require(c) : load(c)
        end
      end

      config.to_prepare(&method(:activate).to_proc)
    end
  end
end
