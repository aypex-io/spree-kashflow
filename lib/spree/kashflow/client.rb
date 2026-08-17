# frozen_string_literal: true

require "savon"

module Spree
  module Kashflow
    ##
    # Stateless SOAP client for the KashFlow API. Only this class may reference Savon —
    # every public method returns plain Ruby (Integer, Array<Hash>, TrueClass) so no SOAP
    # object crosses the gem boundary. KashFlow has no session token: credentials are sent
    # on every call, so nothing is cached between calls.
    #
    class Client
      # @return [String] the WSDL endpoint KashFlow publishes for the SOAP API
      WSDL = "https://securedwebapp.com/api/service.asmx?WSDL"

      # @return [Regexp] matches SOAP faults caused by bad credentials
      AUTH_FAULT = /invalid.*(username|password)|not authori[sz]ed/i

      ##
      # @param username [String] the KashFlow API username
      # @param password [String] the KashFlow API password
      #
      def initialize(username:, password:)
        @username = username
        @password = password
      end

      ##
      # Verifies the configured credentials against the KashFlow API. Does not rescue —
      # the caller decides how to handle a raised error.
      #
      # @return [TrueClass, FalseClass] true when KashFlow accepts the credentials
      # @raise [Spree::Kashflow::Error] when KashFlow rejects the credentials or the
      #   request otherwise fails
      #
      def verify_credentials
        call(:get_currencies)
        true
      end

      ##
      # @return [Array<Hash>] currencies as `{code:, id:}` hashes
      # @raise [Spree::Kashflow::Error] when the request fails
      #
      def currencies
        rows = extract_rows(call(:get_currencies), "GetCurrenciesResponse", "GetCurrenciesResult", "Currencies")
        rows.map { |row| {code: row["CurrencyCode"], id: row["CurrencyId"].to_i} }
      end

      ##
      # @return [Array<Hash>] nominal codes as `{id:, name:}` hashes
      # @raise [Spree::Kashflow::Error] when the request fails
      #
      def nominal_codes
        rows = extract_rows(call(:get_nominal_codes), "GetNominalCodesResponse", "GetNominalCodesResult", "NominalCode")
        rows.map { |row| {id: row["id"].to_i, name: row["Name"]} }
      end

      ##
      # @return [Array<Hash>] bank accounts as `{id:, name:}` hashes
      # @raise [Spree::Kashflow::Error] when the request fails
      #
      def bank_accounts
        rows = extract_rows(call(:get_bank_accounts), "GetBankAccountsResponse", "GetBankAccountsResult", "BankAccount")
        rows.map { |row| {id: row["AccountID"].to_i, name: row["AccountName"]} }
      end

      ##
      # @return [Array<Hash>] invoice payment methods as `{id:, name:}` hashes
      # @raise [Spree::Kashflow::Error] when the request fails
      #
      def payment_methods
        rows = extract_rows(call(:get_inv_pay_methods), "GetInvPayMethodsResponse", "GetInvPayMethodsResult", "PaymentMethod")
        rows.map { |row| {id: row["MethodID"].to_i, name: row["MethodName"]} }
      end

      ##
      # Creates or updates a customer in KashFlow.
      #
      # @param payload [Hash] a KashFlow `Customer` structure
      # @return [Integer] the KashFlow customer id
      # @raise [Spree::Kashflow::Error] when the request fails
      #
      def upsert_customer(payload)
        response = call(:insert_customer, {"custr" => payload})
        response.dig("InsertCustomerResponse", "InsertCustomerResult").to_i
      end

      ##
      # Creates an invoice in KashFlow.
      #
      # @param payload [Hash] a KashFlow `Invoice_TypeDefined` structure
      # @return [Integer] the invoice number KashFlow assigned
      # @raise [Spree::Kashflow::Error] when the request fails
      #
      def create_invoice(payload)
        response = call(:insert_invoice_type_defined, {"Inv_TD" => payload})
        response.dig("InsertInvoice_TypeDefinedResponse", "InsertInvoice_TypeDefinedResult").to_i
      end

      ##
      # Records a payment against an invoice in KashFlow.
      #
      # @param payload [Hash] a KashFlow `Payment` structure
      # @return [TrueClass] true when the payment was recorded
      # @raise [Spree::Kashflow::Error] when the request fails
      #
      def record_invoice_payment(payload)
        call(:insert_invoice_payment, {"InvoicePayment" => payload})
        true
      end

      ##
      # Applies a credit note to an invoice in KashFlow.
      #
      # @param credit_note_number [Integer] the KashFlow credit note id
      # @param invoice_number [Integer] the KashFlow invoice id
      # @return [TrueClass] true when the credit note was applied
      # @raise [Spree::Kashflow::Error] when the request fails
      #
      def apply_credit_note(credit_note_number:, invoice_number:)
        call(:apply_credit_note_to_invoice, {"InvoiceID" => invoice_number, "CreditNoteID" => credit_note_number})
        true
      end

      private

      ##
      # @return [Savon::Client] a Savon client bound to the KashFlow WSDL
      #
      def savon_client
        @savon_client ||= Savon.client(
          wsdl: WSDL,
          log: false,
          convert_response_tags_to: ->(tag) { tag }
        )
      end

      ##
      # Invokes a KashFlow SOAP operation, merging credentials into every request, and
      # maps transport and SOAP-fault errors onto this gem's error hierarchy.
      #
      # @param operation [Symbol] the Savon operation name
      # @param message [Hash] the operation's message body, excluding credentials
      # @return [Hash] the parsed response body
      # @raise [Spree::Kashflow::AuthenticationError] when KashFlow rejects the credentials
      # @raise [Spree::Kashflow::ApiError] when KashFlow refuses the operation
      # @raise [Spree::Kashflow::TransportError] when the KashFlow service could not be reached
      #
      def call(operation, message = {})
        credentials = {"UserName" => @username, "Password" => @password}
        response = savon_client.call(operation, message: credentials.merge(message))
        response.body
      rescue Savon::SOAPFault => e
        fault_message = e.to_hash.dig(:fault, :faultstring) || e.message
        if fault_message.match?(AUTH_FAULT)
          raise AuthenticationError, fault_message
        else
          raise ApiError, fault_message
        end
      rescue Savon::HTTPError, HTTPI::SSLError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout => e
        raise TransportError, e.message
      end

      ##
      # Normalises a KashFlow list response into an array of row hashes.
      #
      # @param body [Hash] the parsed response body
      # @param response_key [String] the top-level response element name
      # @param result_key [String] the result element name nested under the response
      # @param collection_key [String] the element name repeated for each row
      # @return [Array<Hash>] the rows, or an empty array when the response carries none
      #
      def extract_rows(body, response_key, result_key, collection_key)
        result = body.dig(response_key, result_key)
        return [] if result.nil?

        rows = result[collection_key]
        case rows
        when nil then []
        when Array then rows
        else [rows]
        end
      end
    end
  end
end
