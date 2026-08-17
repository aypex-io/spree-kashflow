# frozen_string_literal: true

require "spec_helper"

RSpec.describe "integration registration" do
  let(:registered) { Rails.application.config.spree.integrations }

  it "registers the KashFlow integration" do
    expect(registered).to include(Spree::Integrations::Kashflow)
  end

  it "registers it exactly once" do
    expect(registered.count(Spree::Integrations::Kashflow)).to eq(1)
  end
end

RSpec.describe "subscriber registration" do
  it "registers both KashFlow subscribers" do
    expect(Spree.subscribers).to include(Spree::Kashflow::OrderCompletedSubscriber, Spree::Kashflow::ReimbursementSubscriber)
  end
end
