# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require File.expand_path("../dummy/config/environment.rb", __FILE__)
require "spree_dev_tools/rspec/spec_helper"
require "webmock/rspec"

# No spec may make a live SOAP call. WebMock blocks all outbound HTTP.
WebMock.disable_net_connect!(allow_localhost: true)

Dir[File.join(File.dirname(__FILE__), "support/**/*.rb")].sort.each { |f| require f }
