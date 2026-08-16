# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Integrations::Kashflow do
  subject(:integration) { described_class.new(store: Spree::Store.default) }

  it "is grouped under accounting" do
    expect(described_class.integration_group).to eq("Accounting")
  end

  it "requires a username" do
    integration.preferred_username = nil

    expect(integration).not_to be_valid
  end

  it "requires a password" do
    integration.preferred_password = nil

    expect(integration).not_to be_valid
  end

  it "requires a sales nominal code" do
    integration.preferred_sales_nominal_code = nil

    expect(integration).not_to be_valid
  end

  it "requires a bank account" do
    integration.preferred_bank_account_id = nil

    expect(integration).not_to be_valid
  end

  it "defaults the sales nominal code to blank so it must be chosen" do
    expect(described_class.new.preferred_sales_nominal_code).to be_nil
  end
end
