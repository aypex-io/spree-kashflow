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

    it "raises ApiError instead of returning 0 when KashFlow returns no invoice number" do
      stub_kashflow_call(
        '<InsertInvoice_TypeDefinedResponse xmlns="KashFlowAPI">' \
        "<InsertInvoice_TypeDefinedResult>0</InsertInvoice_TypeDefinedResult>" \
        "</InsertInvoice_TypeDefinedResponse>"
      )

      expect { client.create_invoice({}) }.to raise_error(Spree::Kashflow::ApiError, /invoice number/)
    end

    it "raises ApiError when the result element is absent altogether" do
      stub_kashflow_call('<InsertInvoice_TypeDefinedResponse xmlns="KashFlowAPI" />')

      expect { client.create_invoice({}) }.to raise_error(Spree::Kashflow::ApiError, /invoice number/)
    end
  end

  describe "#upsert_customer" do
    it "returns the KashFlow customer id" do
      stub_kashflow_call(
        '<InsertCustomerResponse xmlns="KashFlowAPI">' \
        "<InsertCustomerResult>555</InsertCustomerResult>" \
        "</InsertCustomerResponse>"
      )

      expect(client.upsert_customer({"Code" => "a@b.com"})).to eq(555)
    end

    it "raises ApiError instead of returning 0 when KashFlow returns no customer id" do
      stub_kashflow_call(
        '<InsertCustomerResponse xmlns="KashFlowAPI">' \
        "<InsertCustomerResult>0</InsertCustomerResult>" \
        "</InsertCustomerResponse>"
      )

      expect { client.upsert_customer({}) }.to raise_error(Spree::Kashflow::ApiError, /customer id/)
    end
  end

  # The defect these cover: KashFlow reports business-level rejections at HTTP
  # 200 with an empty result element and a Status/StatusDetail pair beside it.
  # Uninspected, `nil.to_i` made that a KashFlow identifier of 0 that the job
  # then recorded as a successful sync.
  describe "in-band Status handling" do
    it "raises ApiError carrying StatusDetail when Status is not OK" do
      stub_kashflow_call(
        '<InsertInvoice_TypeDefinedResponse xmlns="KashFlowAPI">' \
        "<InsertInvoice_TypeDefinedResult>0</InsertInvoice_TypeDefinedResult>" \
        "<Status>ERROR</Status><StatusDetail>Nominal code 9999 does not exist</StatusDetail>" \
        "</InsertInvoice_TypeDefinedResponse>"
      )

      expect { client.create_invoice({}) }
        .to raise_error(Spree::Kashflow::ApiError, /Nominal code 9999 does not exist/)
    end

    it "raises AuthenticationError when the Status rejection is a credentials problem" do
      stub_kashflow_call(
        '<InsertCustomerResponse xmlns="KashFlowAPI">' \
        "<InsertCustomerResult>0</InsertCustomerResult>" \
        "<Status>ERROR</Status><StatusDetail>Invalid Username or Password</StatusDetail>" \
        "</InsertCustomerResponse>"
      )

      expect { client.upsert_customer({}) }.to raise_error(Spree::Kashflow::AuthenticationError)
    end

    it "accepts a Status of OK" do
      stub_kashflow_call(
        '<InsertInvoice_TypeDefinedResponse xmlns="KashFlowAPI">' \
        "<InsertInvoice_TypeDefinedResult>4471</InsertInvoice_TypeDefinedResult>" \
        "<Status>OK</Status><StatusDetail />" \
        "</InsertInvoice_TypeDefinedResponse>"
      )

      expect(client.create_invoice({})).to eq(4471)
    end
  end

  # The assertion whose absence hid the missing ArrayOfInvoiceLine wrapper: no
  # other spec in this suite looks at a SOAP request body, only at what the
  # stubbed response deserialises to.
  describe "the SOAP request body it actually sends" do
    it "wraps each line in an <InvoiceLine> element inside <Lines>" do
      captured = nil
      stub_request(:post, KashflowSoap::ENDPOINT)
        .with { |request| captured = request.body }
        .to_return(
          status: 200,
          body: <<~XML,
            <?xml version="1.0" encoding="utf-8"?>
            <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
              <soap:Body><InsertInvoice_TypeDefinedResponse xmlns="KashFlowAPI">
                <InsertInvoice_TypeDefinedResult>4471</InsertInvoice_TypeDefinedResult>
              </InsertInvoice_TypeDefinedResponse></soap:Body>
            </soap:Envelope>
          XML
          headers: {"Content-Type" => "text/xml; charset=utf-8"}
        )

      client.create_invoice(
        "CustomerID" => 1,
        "Lines" => {"InvoiceLine" => [{"Rate" => 10}, {"Rate" => 20}]}
      )

      expect(captured).to include(
        "<tns:Lines><tns:InvoiceLine><tns:Rate>10</tns:Rate></tns:InvoiceLine>" \
        "<tns:InvoiceLine><tns:Rate>20</tns:Rate></tns:InvoiceLine></tns:Lines>"
      )
    end

    it "sends the credentials on every request" do
      captured = nil
      stub_request(:post, KashflowSoap::ENDPOINT)
        .with { |request| captured = request.body }
        .to_return(
          status: 200,
          body: '<?xml version="1.0" encoding="utf-8"?>' \
                '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>' \
                '<GetCurrenciesResponse xmlns="KashFlowAPI"><GetCurrenciesResult /></GetCurrenciesResponse>' \
                "</soap:Body></soap:Envelope>",
          headers: {"Content-Type" => "text/xml; charset=utf-8"}
        )

      client.verify_credentials

      expect(captured).to include("<tns:UserName>user</tns:UserName>", "<tns:Password>secret</tns:Password>")
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

    # A DNS or TLS failure used to bypass TransportError entirely, so the jobs'
    # `retry_on Spree::Kashflow::TransportError` never fired for either.
    [SocketError, Errno::ETIMEDOUT, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError].each do |error_class|
      it "raises TransportError for #{error_class}" do
        stub_request(:post, KashflowSoap::ENDPOINT).to_raise(error_class)

        expect { client.create_invoice({}) }.to raise_error(Spree::Kashflow::TransportError)
      end
    end
  end
end
