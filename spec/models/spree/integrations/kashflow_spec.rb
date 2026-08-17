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

  describe "#nominal_code_options" do
    before do
      integration.preferred_username = "kashflow-user"
      integration.preferred_password = "kashflow-pass"
    end

    it "returns name/id pairs when the client responds" do
      client = instance_double(Spree::Kashflow::Client, nominal_codes: [{id: 4000, name: "Sales"}])
      allow(integration).to receive(:client).and_return(client)

      expect(integration.nominal_code_options).to eq([["Sales", 4000]])
    end

    it "returns no options when the client has no nominal codes" do
      client = instance_double(Spree::Kashflow::Client, nominal_codes: [])
      allow(integration).to receive(:client).and_return(client)

      expect(integration.nominal_code_options).to eq([])
    end

    it "returns no options when the client fails to connect" do
      client = instance_double(Spree::Kashflow::Client)
      allow(client).to receive(:nominal_codes).and_raise(Spree::Kashflow::TransportError, "timeout")
      allow(integration).to receive(:client).and_return(client)

      expect(integration.nominal_code_options).to eq([])
    end

    it "returns no options when the client rejects the credentials" do
      client = instance_double(Spree::Kashflow::Client)
      allow(client).to receive(:nominal_codes).and_raise(Spree::Kashflow::AuthenticationError, "invalid username")
      allow(integration).to receive(:client).and_return(client)

      expect(integration.nominal_code_options).to eq([])
    end

    it "returns no options when credentials are blank" do
      integration.preferred_username = nil
      integration.preferred_password = nil

      expect(integration.nominal_code_options).to eq([])
    end

    it "does not call the client when credentials are blank" do
      integration.preferred_username = nil
      integration.preferred_password = nil
      allow(integration).to receive(:client)

      integration.nominal_code_options

      expect(integration).not_to have_received(:client)
    end
  end

  describe "#bank_account_options" do
    before do
      integration.preferred_username = "kashflow-user"
      integration.preferred_password = "kashflow-pass"
    end

    it "returns name/id pairs when the client responds" do
      client = instance_double(Spree::Kashflow::Client, bank_accounts: [{id: 1, name: "Current Account"}])
      allow(integration).to receive(:client).and_return(client)

      expect(integration.bank_account_options).to eq([["Current Account", 1]])
    end

    it "returns no options when the client has no bank accounts" do
      client = instance_double(Spree::Kashflow::Client, bank_accounts: [])
      allow(integration).to receive(:client).and_return(client)

      expect(integration.bank_account_options).to eq([])
    end

    it "returns no options when the client fails to connect" do
      client = instance_double(Spree::Kashflow::Client)
      allow(client).to receive(:bank_accounts).and_raise(Spree::Kashflow::TransportError, "timeout")
      allow(integration).to receive(:client).and_return(client)

      expect(integration.bank_account_options).to eq([])
    end

    it "returns no options when the client rejects the credentials" do
      client = instance_double(Spree::Kashflow::Client)
      allow(client).to receive(:bank_accounts).and_raise(Spree::Kashflow::AuthenticationError, "invalid username")
      allow(integration).to receive(:client).and_return(client)

      expect(integration.bank_account_options).to eq([])
    end

    it "returns no options when credentials are blank" do
      integration.preferred_username = nil
      integration.preferred_password = nil

      expect(integration.bank_account_options).to eq([])
    end

    it "does not call the client when credentials are blank" do
      integration.preferred_username = nil
      integration.preferred_password = nil
      allow(integration).to receive(:client)

      integration.bank_account_options

      expect(integration).not_to have_received(:client)
    end
  end

  describe "#payment_method_options" do
    before do
      integration.preferred_username = "kashflow-user"
      integration.preferred_password = "kashflow-pass"
    end

    it "returns name/id pairs when the client responds" do
      client = instance_double(Spree::Kashflow::Client, payment_methods: [{id: 1, name: "Bank Transfer"}])
      allow(integration).to receive(:client).and_return(client)

      expect(integration.payment_method_options).to eq([["Bank Transfer", 1]])
    end

    it "returns no options when the client has no payment methods" do
      client = instance_double(Spree::Kashflow::Client, payment_methods: [])
      allow(integration).to receive(:client).and_return(client)

      expect(integration.payment_method_options).to eq([])
    end

    it "returns no options when the client fails to connect" do
      client = instance_double(Spree::Kashflow::Client)
      allow(client).to receive(:payment_methods).and_raise(Spree::Kashflow::TransportError, "timeout")
      allow(integration).to receive(:client).and_return(client)

      expect(integration.payment_method_options).to eq([])
    end

    it "returns no options when the client rejects the credentials" do
      client = instance_double(Spree::Kashflow::Client)
      allow(client).to receive(:payment_methods).and_raise(Spree::Kashflow::AuthenticationError, "invalid username")
      allow(integration).to receive(:client).and_return(client)

      expect(integration.payment_method_options).to eq([])
    end

    it "returns no options when credentials are blank" do
      integration.preferred_username = nil
      integration.preferred_password = nil

      expect(integration.payment_method_options).to eq([])
    end

    it "does not call the client when credentials are blank" do
      integration.preferred_username = nil
      integration.preferred_password = nil
      allow(integration).to receive(:client)

      integration.payment_method_options

      expect(integration).not_to have_received(:client)
    end
  end

  describe "memoisation" do
    before do
      integration.preferred_username = "kashflow-user"
      integration.preferred_password = "kashflow-pass"
    end

    it "calls the client only once across repeated nominal_code_options calls in the same instance" do
      client = instance_double(Spree::Kashflow::Client, nominal_codes: [{id: 4000, name: "Sales"}])
      allow(integration).to receive(:client).and_return(client)

      2.times { integration.nominal_code_options }

      expect(client).to have_received(:nominal_codes).once
    end
  end
end
