# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow do
  it "exposes a semantic version string" do
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "loads its engine" do
    expect(defined?(Spree::Kashflow::Engine)).to eq("constant")
  end
end
