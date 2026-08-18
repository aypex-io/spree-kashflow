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

      # @return [String] the in-band `Status` value KashFlow returns on success.
      #
      # The WSDL declares `Status` as a bare `s:string` on every `*Response`
      # element (`minOccurs="0"`), with no `<s:enumeration>` and no
      # `<wsdl:documentation>` naming the success value — so this constant is
      # KashFlow's documented convention (`"OK"`), not something the schema
      # pins down. Comparison is case-insensitive, and an *absent* `Status`
      # (legal, since `minOccurs="0"`) is treated as success; only a present
      # `Status` that is not `"OK"` is a business-level rejection.
      SUCCESS_STATUS = "OK"

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
      # Creates or updates a customer in KashFlow, keyed on the customer `Code`.
      #
      # KashFlow publishes no `InsertOrUpdateCustomer`, so an upsert is a lookup
      # followed by an `UpdateCustomer` or an `InsertCustomer`. The lookup is not
      # optional: customer codes are stable per customer (that is what keeps one
      # KashFlow customer per Spree customer rather than one per order), so an
      # unconditional insert succeeds exactly once and every subsequent order for
      # that customer is rejected with "Customer Code is not unique" — with no
      # invoice posted.
      #
      # @param payload [Hash] a KashFlow `Customer` structure, whose `"Code"`
      #   identifies the customer
      # @return [Integer] the KashFlow customer id, existing or newly assigned
      # @raise [Spree::Kashflow::ApiError] when the request fails, or when
      #   KashFlow returns no usable customer id
      # @raise [Spree::Kashflow::AuthenticationError] when KashFlow rejects the
      #   credentials
      #
      def upsert_customer(payload)
        existing_id = customer_id_for_code(payload["Code"])
        return update_customer(existing_id, payload) if existing_id

        response = call(:insert_customer, {"custr" => payload})
        result = response.dig("InsertCustomerResponse", "InsertCustomerResult")
        assert_identifier!(result, "customer id")
      end

      ##
      # Creates an invoice in KashFlow.
      #
      # @param payload [Hash] a KashFlow `Invoice_TypeDefined` structure
      # @return [Integer] the invoice number KashFlow assigned
      # @raise [Spree::Kashflow::ApiError] when the request fails, or when
      #   KashFlow returns no usable invoice number
      #
      def create_invoice(payload)
        response = call(:insert_invoice_type_defined, {"Inv_TD" => payload})
        result = response.dig("InsertInvoice_TypeDefinedResponse", "InsertInvoice_TypeDefinedResult")
        assert_identifier!(result, "invoice number")
      end

      ##
      # Records a payment against an invoice in KashFlow.
      #
      # The WSDL declares `InsertInvoicePaymentResult` as an `s:int` — the id of
      # the payment KashFlow created. A `0` is therefore a rejection reported
      # without a `Status`, and returning `true` regardless would leave the
      # invoice permanently unpaid while the caller recorded a successful sync.
      #
      # @param payload [Hash] a KashFlow `Payment` structure
      # @return [TrueClass] true when the payment was recorded
      # @raise [Spree::Kashflow::ApiError] when the request fails, or when
      #   KashFlow returns no payment id
      #
      def record_invoice_payment(payload)
        response = call(:insert_invoice_payment, {"InvoicePayment" => payload})
        result = response.dig("InsertInvoicePaymentResponse", "InsertInvoicePaymentResult")
        assert_identifier!(result, "payment id")
        true
      end

      ##
      # Applies a credit note to an invoice in KashFlow.
      #
      # The WSDL declares `applyCreditNoteToInvoiceResult` as an `s:boolean`.
      # A `false` is a refusal to link, and swallowing it produces exactly the
      # orphan credit note {SyncRefundJob}'s precondition guard exists to
      # prevent — a credit note sitting in KashFlow attached to nothing.
      #
      # @param credit_note_number [Integer] the KashFlow credit note id
      # @param invoice_number [Integer] the KashFlow invoice id
      # @return [TrueClass] true when the credit note was applied
      # @raise [Spree::Kashflow::ApiError] when the request fails, or when
      #   KashFlow refuses to link the credit note
      #
      def apply_credit_note(credit_note_number:, invoice_number:)
        response = call(:apply_credit_note_to_invoice, {"InvoiceID" => invoice_number, "CreditNoteID" => credit_note_number})
        result = response.dig("applyCreditNoteToInvoiceResponse", "applyCreditNoteToInvoiceResult")
        assert_accepted!(result, "did not apply credit note #{credit_note_number} to invoice #{invoice_number}")
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
      # maps transport errors, SOAP faults and in-band `Status` rejections onto this
      # gem's error hierarchy.
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
        body = coerce_temporal(credentials.merge(message))
        response = savon_client.call(operation, message: body)
        body = response.body
        assert_status!(body)
        body
      rescue Savon::SOAPFault => e
        fault_message = e.to_hash.dig(:fault, :faultstring) || e.message
        raise_business_error(fault_message)
      rescue Savon::HTTPError, HTTPI::SSLError, OpenSSL::SSL::SSLError, SocketError,
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
        Net::OpenTimeout, Net::ReadTimeout => e
        raise TransportError, e.message
      end

      ##
      # Looks a customer up by its KashFlow `Code`.
      #
      # How KashFlow signals "no such customer" here is undocumented, and no
      # spec that stubs the SOAP layer can settle it, so both shapes it can
      # plausibly take are treated as absent: an empty `GetCustomerResult`, and
      # an in-band business rejection. Only {ApiError} is swallowed — an
      # authentication or transport failure must keep propagating, since
      # reading either as "absent" would turn it into a duplicate insert and
      # put the caller back on the collision this method exists to avoid.
      #
      # @param code [String, nil] the KashFlow customer code
      # @return [Integer, nil] the customer id, or nil when no customer holds
      #   that code
      #
      def customer_id_for_code(code)
        return nil if code.to_s.strip.empty?

        result = call(:get_customer, {"CustomerCode" => code})
          .dig("GetCustomerResponse", "GetCustomerResult")
        return nil unless result.is_a?(Hash)

        identifier = result["CustomerID"].to_i
        identifier.zero? ? nil : identifier
      rescue ApiError
        nil
      end

      ##
      # Updates an existing KashFlow customer in place.
      #
      # `CustomerID` is prepended rather than merged onto the end because it is
      # the first element of the WSDL's `Customer` sequence, and an ASMX
      # endpoint enforcing that sequence drops or mis-binds an out-of-order
      # element rather than raising — an update whose id was dropped would write
      # to the wrong customer, or to none, and still return successfully.
      #
      # `UpdateCustomerResult` is a `s:string`, not the customer id, so the id
      # is carried over from the lookup instead of being read off the response.
      #
      # @param identifier [Integer] the KashFlow customer id
      # @param payload [Hash] a KashFlow `Customer` structure
      # @return [Integer] the customer id that was updated
      #
      def update_customer(identifier, payload)
        call(:update_customer, {"custr" => {"CustomerID" => identifier}.merge(payload)})
        identifier
      end

      ##
      # Rewrites every temporal value in an outgoing message to xsd `dateTime`.
      #
      # KashFlow types every date field in the WSDL as `s:dateTime`, and its
      # .NET `XmlSerializer` rejects the *entire* envelope with a
      # `FormatException` ("is not a valid AllXsd value") when one of them is
      # not valid xsd — the invoice is never created, and the fault names only
      # a character offset, not the field.
      #
      # Gyoku cannot be relied on to do this. It type-switches with
      # `case/when`, i.e. `Module#===`, so:
      # - `ActiveSupport::TimeWithZone` is a *delegator*, not a `Time`
      #   subclass, and misses the branch entirely -> `to_s`
      #   ("2026-08-18 10:53:48 UTC").
      # - plain `Time` is likewise emitted via `to_s` by Gyoku 1.4.
      # - `Date` serialises as `2026-08-18`, an xsd `date`, not the `dateTime`
      #   the schema asks for.
      #
      # `Time.current` and every Active Record datetime attribute return
      # `TimeWithZone`, so the broken path was the default one, which is why
      # every caller was affected. Normalising here rather than at each call
      # site keeps the wire format owned by the one class that touches the
      # wire, and means a date field added to any future payload is correct
      # without the author having to know this.
      #
      # Values are converted to UTC first so the instant is preserved and the
      # emitted form is unambiguous (`...Z`) regardless of the app's zone.
      #
      # @param value [Object] any message value; Hashes and Arrays are walked
      # @return [Object] the value with temporals replaced by xsd strings
      #
      def coerce_temporal(value)
        case value
        when Hash then value.transform_values { |element| coerce_temporal(element) }
        when Array then value.map { |element| coerce_temporal(element) }
        when ActiveSupport::TimeWithZone, Time then value.utc.xmlschema
        when DateTime then value.to_time.utc.xmlschema
        when Date then value.to_time(:utc).xmlschema
        else value
        end
      end

      ##
      # KashFlow reports business-level rejections *in band*: the SOAP call
      # succeeds at HTTP 200 with an empty result element and a `Status` /
      # `StatusDetail` pair beside it. Left uninspected, a rejection reads as a
      # `nil` result and coerces to `0` — a value the caller would then record
      # as a real KashFlow identifier. See {SUCCESS_STATUS} for why the success
      # value is a convention rather than a schema-declared enumeration.
      #
      # @param body [Hash] the parsed response body
      # @return [void]
      # @raise [Spree::Kashflow::AuthenticationError] when the rejection is a
      #   credentials problem
      # @raise [Spree::Kashflow::ApiError] for any other non-success `Status`
      #
      def assert_status!(body)
        envelope = body.values.detect { |value| value.is_a?(Hash) }
        return if envelope.nil?

        status = envelope["Status"]
        return if status.nil?
        return if status.to_s.strip.casecmp(SUCCESS_STATUS).zero?

        detail = envelope["StatusDetail"]
        raise_business_error([status, detail].compact_blank.join(": "))
      end

      ##
      # @param message [String] the message KashFlow refused the request with
      # @return [void]
      # @raise [Spree::Kashflow::AuthenticationError] when the message names a
      #   credentials problem
      # @raise [Spree::Kashflow::ApiError] otherwise
      #
      def raise_business_error(message)
        if message.match?(AUTH_FAULT)
          raise AuthenticationError, message
        else
          raise ApiError, message
        end
      end

      ##
      # KashFlow returns `0` (or nothing at all) where it means "refused", and
      # a `0` recorded as an identifier is worse than a raised error: it looks
      # like a successful sync, satisfies the caller's idempotency check, and
      # blocks every retry.
      #
      # @param result [Object, nil] the raw result element
      # @param label [String] what the identifier is, for the error message
      # @return [Integer] the identifier
      # @raise [Spree::Kashflow::ApiError] when the result is nil or zero
      #
      def assert_identifier!(result, label)
        identifier = result.to_i
        return identifier unless result.nil? || identifier.zero?

        raise ApiError, "KashFlow returned no #{label} (result: #{result.inspect})"
      end

      ##
      # The counterpart of {#assert_identifier!} for the operations the WSDL types
      # as `s:boolean` rather than `s:int`. Savon hands the element back as the
      # string `"true"` / `"false"`, so only an explicit `"true"` is acceptance;
      # `false`, `nil` and an absent element are all rejections.
      #
      # @param result [Object, nil] the raw result element
      # @param message [String] what KashFlow refused, for the error message
      # @return [void]
      # @raise [Spree::Kashflow::ApiError] when the result is not true
      #
      def assert_accepted!(result, message)
        return if result.to_s.strip.casecmp("true").zero?

        raise ApiError, "KashFlow #{message} (result: #{result.inspect})"
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
