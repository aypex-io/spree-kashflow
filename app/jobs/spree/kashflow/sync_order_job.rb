# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Posts a completed order to KashFlow as an invoice.
    #
    # Idempotent by design: a second run for the same order is a no-op once the
    # order carries a {Metafields::ORDER_INVOICE_NUMBER} metafield, which is what
    # makes it safe to retry and to enqueue this job from more than one trigger
    # (a subscriber and a decorator both firing for the same event, for instance)
    # without double-booking. Takes an id, never an {Spree::Order}, so ActiveJob's
    # argument serialisation never has to round-trip a whole AR object.
    #
    class SyncOrderJob < Spree::BaseJob
      # Bad credentials will never succeed on retry, so retrying only fills the
      # queue; the failure is written to {Metafields::ORDER_SYNC_ERROR} before the
      # job discards (see the `rescue` in {#perform}, which runs before ActiveJob's
      # `discard_on` handler).
      discard_on Spree::Kashflow::AuthenticationError

      # KashFlow being briefly unreachable is exactly the case retrying recovers
      # from automatically.
      retry_on Spree::Kashflow::TransportError, wait: :polynomially_longer, attempts: 5

      ##
      # @param order_id [Integer, String] the {Spree::Order} id
      # @return [void]
      # @raise [Spree::Kashflow::Error] any subclass raised while posting; the
      #   message is written to {Metafields::ORDER_SYNC_ERROR} first
      #
      def perform(order_id)
        order = Spree::Order.find_by(id: order_id)
        return if order.nil?

        integration = Spree::Integrations::Kashflow.active.find_by(store: order.store)
        return if integration.nil?

        return if order.has_metafield?(Metafields::ORDER_INVOICE_NUMBER)

        sync(order, integration)
      rescue Spree::Kashflow::Error => e
        Metafields.write(order, Metafields::ORDER_SYNC_ERROR, e.message)
        raise
      end

      private

      ##
      # Every KashFlow call this job makes happens before any metafield is
      # written, and {Metafields::ORDER_INVOICE_NUMBER} — the idempotency key —
      # is written last of all. Writing it earlier makes a failure in a
      # follow-on call (a wrong `PayAccount` rejecting the payment, say)
      # unrecoverable: the retry sees the key, no-ops, and the invoice stays
      # unpaid in KashFlow forever. Written last, a failed follow-on leaves the
      # order retryable.
      #
      # @param order [Spree::Order]
      # @param integration [Spree::Integrations::Kashflow]
      # @return [void]
      #
      def sync(order, integration)
        client = integration.client
        assert_currency_enabled!(order, client)

        customer_id = client.upsert_customer(CustomerPayload.new(order).to_h)
        invoice_number = client.create_invoice(invoice_envelope(order, integration, customer_id))
        record_payment(order, integration, client, invoice_number) if order.paid?

        Metafields.write(order, Metafields::ORDER_CUSTOMER_CODE, customer_id)
        Metafields.write(order, Metafields::ORDER_SYNCED_AT, Time.current)
        Metafields.write(order, Metafields::ORDER_SYNC_ERROR, nil)
        Metafields.write(order, Metafields::ORDER_INVOICE_NUMBER, invoice_number)
      end

      ##
      # Booking a USD order as GBP is worse than not booking it, so this is checked
      # before anything is posted.
      #
      # @param order [Spree::Order]
      # @param client [Spree::Kashflow::Client]
      # @return [void]
      # @raise [Spree::Kashflow::ApiError] when the order's currency is not among
      #   the currencies enabled on the KashFlow account
      #
      def assert_currency_enabled!(order, client)
        enabled = client.currencies.map { |currency| currency[:code] }
        return if enabled.include?(order.currency)

        raise Spree::Kashflow::ApiError, "Currency #{order.currency.inspect} is not enabled in KashFlow (enabled: #{enabled.join(", ")})"
      end

      ##
      # Wraps {InvoicePayload#to_h}'s four fields in the envelope the WSDL `Invoice`
      # complex type also declares `minOccurs="1"`, which Task 5 deliberately left
      # to this job because they depend on things Task 5's mapper doesn't have: the
      # customer id from the upsert call, and this job's own idempotency/payment
      # state. Keys are emitted in `Invoice_TypeDefined`'s WSDL `<s:sequence>`
      # order — Savon serialises a Hash body in insertion order, and a .NET ASMX
      # endpoint enforcing that sequence drops or mis-binds an out-of-order
      # element rather than raising.
      #
      # `Lines` is nested under an explicit `"InvoiceLine"` key because the WSDL
      # types it as `ArrayOfInvoiceLine`, whose single member is an unbounded
      # `InvoiceLine` element. Handing Gyoku a bare Array instead repeats
      # `<Lines>` as a sibling per line rather than wrapping them, which an ASMX
      # `XmlSerializer` skips as unknown children — posting an invoice with
      # header totals and no lines, and still returning an invoice number.
      #
      # Defaults for the fields with no natural source:
      # - `InvoiceDBID`, `InvoiceNumber`: unknown before KashFlow assigns them on
      #   insert, so `0`.
      # - `DueDate`: same as `InvoiceDate` — the order is already completed (and
      #   frequently already paid), so there are no payment terms to express.
      # - `SuppressTotal`: `0` — show the total on the rendered invoice.
      # - `ProjectID`: `0` — no KashFlow project is associated with these orders.
      # - `ExchangeRate`: `1` — {#assert_currency_enabled!} has already refused to
      #   post an order whose currency isn't one KashFlow itself is configured
      #   for, so no conversion applies.
      # - `CustomerReference`: the Spree order number, so an accountant
      #   reconciling a discrepancy in KashFlow can find the order it came from.
      # - `CISRCNetAmount`, `CISRCVatAmount`, `IsCISReverseCharge`: UK Construction
      #   Industry Scheme reverse-charge fields. Structurally required by the
      #   schema but not applicable to this integration (a supplements retailer,
      #   not a CIS contractor), so `0` / `false` rather than `nil` — `nil` would
      #   depend on Gyoku emitting `xsi:nil="true"` and the ASMX deserialiser
      #   accepting it, an assumption no spec here can exercise since every spec
      #   stubs the SOAP layer. `0` is arithmetically neutral and unambiguous on
      #   the wire; revisit if a sandbox call ever shows KashFlow prefers null.
      #
      # @param order [Spree::Order]
      # @param integration [Spree::Integrations::Kashflow]
      # @param customer_id [Integer] the id returned by `Client#upsert_customer`
      # @return [Hash{String => Object}] a KashFlow `Invoice` structure, envelope
      #   fields and {InvoicePayload#to_h}'s fields together, in WSDL sequence order
      #
      def invoice_envelope(order, integration, customer_id)
        payload = InvoicePayload.new(order, integration: integration).to_h
        invoice_date = order.completed_at || Time.current

        {
          "InvoiceDBID" => 0,
          "InvoiceNumber" => 0,
          "InvoiceDate" => invoice_date,
          "DueDate" => invoice_date,
          "CustomerID" => customer_id,
          "Paid" => order.paid? ? 1 : 0,
          "CustomerReference" => order.number,
          "SuppressTotal" => 0,
          "ProjectID" => 0,
          "CurrencyCode" => payload["CurrencyCode"],
          "ExchangeRate" => BigDecimal(1),
          "Lines" => {"InvoiceLine" => payload["Lines"]},
          "NetAmount" => payload["NetAmount"],
          "VATAmount" => payload["VATAmount"],
          "AmountPaid" => order.paid? ? order.total : BigDecimal(0),
          "CISRCNetAmount" => 0,
          "CISRCVatAmount" => 0,
          "IsCISReverseCharge" => false
        }
      end

      ##
      # @param order [Spree::Order]
      # @param integration [Spree::Integrations::Kashflow]
      # @param client [Spree::Kashflow::Client]
      # @param invoice_number [Integer]
      # @return [void]
      #
      def record_payment(order, integration, client, invoice_number)
        client.record_invoice_payment(
          "PayID" => 0,
          "PayInvoice" => invoice_number,
          "PayDate" => order.completed_at || Time.current,
          "PayMethod" => integration.preferred_payment_method_id,
          "PayAccount" => integration.preferred_bank_account_id,
          "PayAmount" => order.total
        )
      end
    end
  end
end
