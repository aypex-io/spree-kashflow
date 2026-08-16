# frozen_string_literal: true

require "bundler"
Bundler::GemHelper.install_tasks

require "rspec/core/rake_task"
require "spree/testing_support/extension_rake"

RSpec::Core::RakeTask.new

task default: :spec

desc "Generates a dummy app for testing"
task :test_app do
  # Must be the require path, not the gem name -- spree_core's common:test_app
  # does a literal `require ENV['LIB_NAME']` and templates the same string into
  # the generated dummy app.
  ENV["LIB_NAME"] = "spree/kashflow"
  ENV["DB"] ||= "postgres"
  Rake::Task["extension:test_app"].execute(install_admin: true)
end
