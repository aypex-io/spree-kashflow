# frozen_string_literal: true

# Bundler auto-requires a gem by its *name*, so `gem "spree-kashflow"` in a host
# Gemfile issues `require "spree-kashflow"`. The real entry point is
# `spree/kashflow` (matching the Spree::Kashflow namespace), so this shim keeps
# the default `Bundler.require` working.
require "spree/kashflow"
