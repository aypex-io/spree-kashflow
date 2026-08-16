# frozen_string_literal: true

lib = File.expand_path("../lib/", __FILE__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

require "spree/kashflow/version"

Gem::Specification.new do |s|
  s.platform = Gem::Platform::RUBY
  s.name = "spree-kashflow"
  s.version = Spree::Kashflow::VERSION
  s.summary = "KashFlow accounting integration for Spree"
  s.description = "Pushes completed Spree orders to KashFlow as invoices and refunds as credit " \
                  "notes over the KashFlow SOAP API, configured per store through Spree's " \
                  "Integrations framework."
  s.required_ruby_version = ">= 3.3"

  s.author = "Aypex"
  s.email = "hello@aypex.io"
  s.homepage = "https://github.com/aypex-io/spree-kashflow"
  s.license = "MIT"

  s.metadata = {
    "source_code_uri" => s.homepage,
    "bug_tracker_uri" => "#{s.homepage}/issues",
    "changelog_uri" => "#{s.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  s.files = Dir["{app,config,lib}/**/*", "LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  s.require_path = "lib"

  s.add_dependency "savon", "~> 2.17"
  s.add_dependency "spree", ">= 5.6.0"
  s.add_dependency "spree_extension"
end
