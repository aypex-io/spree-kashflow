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

  describe "#currencies" do
    it "returns each currency as a hash with coerced types" do
      stub_kashflow_call(
        '<GetCurrenciesResponse xmlns="KashFlowAPI"><GetCurrenciesResult>' \
        "<Currencies><CurrencyId>1</CurrencyId><CurrencyCode>GBP</CurrencyCode>" \
        "<ExchangeRate>1</ExchangeRate><isDefault>1</isDefault></Currencies>" \
        "<Currencies><CurrencyId>2</CurrencyId><CurrencyCode>USD</CurrencyCode>" \
        "<ExchangeRate>1.3</ExchangeRate><isDefault>0</isDefault></Currencies>" \
        "</GetCurrenciesResult></GetCurrenciesResponse>"
      )

      expect(client.currencies).to eq(
        [{code: "GBP", id: 1}, {code: "USD", id: 2}]
      )
    end

    it "returns an empty array when KashFlow has no currencies" do
      stub_kashflow_call('<GetCurrenciesResponse xmlns="KashFlowAPI"><GetCurrenciesResult /></GetCurrenciesResponse>')

      expect(client.currencies).to eq([])
    end
  end

  describe "#nominal_codes" do
    it "returns each nominal code as a hash with coerced types" do
      stub_kashflow_call(
        '<GetNominalCodesResponse xmlns="KashFlowAPI"><GetNominalCodesResult>' \
        "<NominalCode><id>10</id><Code>4000</Code><Name>Sales</Name>" \
        "<debit>0</debit><credit>0</credit><balance>0</balance></NominalCode>" \
        "<NominalCode><id>11</id><Code>5000</Code><Name>Purchases</Name>" \
        "<debit>0</debit><credit>0</credit><balance>0</balance></NominalCode>" \
        "</GetNominalCodesResult></GetNominalCodesResponse>"
      )

      expect(client.nominal_codes).to eq(
        [{id: 10, name: "Sales"}, {id: 11, name: "Purchases"}]
      )
    end

    it "returns an empty array when KashFlow has no nominal codes" do
      stub_kashflow_call('<GetNominalCodesResponse xmlns="KashFlowAPI"><GetNominalCodesResult /></GetNominalCodesResponse>')

      expect(client.nominal_codes).to eq([])
    end
  end

  describe "#bank_accounts" do
    it "returns each bank account as a hash with coerced types" do
      stub_kashflow_call(
        '<GetBankAccountsResponse xmlns="KashFlowAPI"><GetBankAccountsResult>' \
        "<BankAccount><AccountID>1</AccountID><AccountName>Current</AccountName>" \
        "<AccountCode>1200</AccountCode></BankAccount>" \
        "<BankAccount><AccountID>2</AccountID><AccountName>Savings</AccountName>" \
        "<AccountCode>1210</AccountCode></BankAccount>" \
        "</GetBankAccountsResult></GetBankAccountsResponse>"
      )

      expect(client.bank_accounts).to eq(
        [{id: 1, name: "Current"}, {id: 2, name: "Savings"}]
      )
    end

    it "returns a one-element array when KashFlow has a single bank account" do
      stub_kashflow_call(
        '<GetBankAccountsResponse xmlns="KashFlowAPI"><GetBankAccountsResult>' \
        "<BankAccount><AccountID>1</AccountID><AccountName>Current</AccountName>" \
        "<AccountCode>1200</AccountCode></BankAccount>" \
        "</GetBankAccountsResult></GetBankAccountsResponse>"
      )

      expect(client.bank_accounts).to eq([{id: 1, name: "Current"}])
    end

    it "returns an empty array when KashFlow has no bank accounts" do
      stub_kashflow_call('<GetBankAccountsResponse xmlns="KashFlowAPI"><GetBankAccountsResult /></GetBankAccountsResponse>')

      expect(client.bank_accounts).to eq([])
    end
  end

  describe "#payment_methods" do
    it "returns each payment method as a hash with coerced types" do
      stub_kashflow_call(
        '<GetInvPayMethodsResponse xmlns="KashFlowAPI"><GetInvPayMethodsResult>' \
        "<PaymentMethod><MethodID>1</MethodID><MethodName>Bank Transfer</MethodName></PaymentMethod>" \
        "<PaymentMethod><MethodID>2</MethodID><MethodName>Credit Card</MethodName></PaymentMethod>" \
        "</GetInvPayMethodsResult></GetInvPayMethodsResponse>"
      )

      expect(client.payment_methods).to eq(
        [{id: 1, name: "Bank Transfer"}, {id: 2, name: "Credit Card"}]
      )
    end

    it "returns a one-element array when KashFlow has a single payment method" do
      stub_kashflow_call(
        '<GetInvPayMethodsResponse xmlns="KashFlowAPI"><GetInvPayMethodsResult>' \
        "<PaymentMethod><MethodID>1</MethodID><MethodName>Bank Transfer</MethodName></PaymentMethod>" \
        "</GetInvPayMethodsResult></GetInvPayMethodsResponse>"
      )

      expect(client.payment_methods).to eq([{id: 1, name: "Bank Transfer"}])
    end

    it "returns an empty array when KashFlow has no payment methods" do
      stub_kashflow_call('<GetInvPayMethodsResponse xmlns="KashFlowAPI"><GetInvPayMethodsResult /></GetInvPayMethodsResponse>')

      expect(client.payment_methods).to eq([])
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
