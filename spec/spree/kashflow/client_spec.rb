# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow::Client do
  subject(:client) { described_class.new(username: "user", password: "secret") }

  before { stub_kashflow_wsdl }

  describe "#verify_credentials" do
    it "returns true when KashFlow accepts the credentials" do
      stub_kashflow_call('<GetCurrenciesResponse xmlns="KashFlowAPI"><GetCurrenciesResult /></GetCurrenciesResponse>')

      expect(client.verify_credentials).to be(true)
    end
  end

  describe "#create_invoice" do
    it "returns the invoice number KashFlow assigned" do
      stub_kashflow_call(
        '<InsertInvoice_TypeDefinedResponse xmlns="KashFlowAPI">' \
        "<InsertInvoice_TypeDefinedResult>4471</InsertInvoice_TypeDefinedResult>" \
        "</InsertInvoice_TypeDefinedResponse>"
      )

      expect(client.create_invoice({"CustomerID" => 1})).to eq(4471)
    end
  end

  describe "error mapping" do
    it "raises AuthenticationError when KashFlow rejects the credentials" do
      stub_kashflow_call(
        "<soap:Fault><faultcode>soap:Server</faultcode>" \
        "<faultstring>Invalid username or password</faultstring></soap:Fault>",
        status: 500
      )

      expect { client.verify_credentials }.to raise_error(Spree::Kashflow::AuthenticationError)
    end

    it "raises ApiError for other SOAP faults" do
      stub_kashflow_call(
        "<soap:Fault><faultcode>soap:Server</faultcode>" \
        "<faultstring>Nominal code does not exist</faultstring></soap:Fault>",
        status: 500
      )

      expect { client.create_invoice({}) }.to raise_error(Spree::Kashflow::ApiError)
    end

    it "raises TransportError when the connection fails" do
      stub_request(:post, KashflowSoap::ENDPOINT).to_timeout

      expect { client.create_invoice({}) }.to raise_error(Spree::Kashflow::TransportError)
    end
  end
end
