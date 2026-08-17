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
        order.set_metafield(Metafields::ORDER_SYNC_ERROR, e.message)
        raise
      end

      private

      ##
      # @param order [Spree::Order]
      # @param integration [Spree::Integrations::Kashflow]
      # @return [void]
      #
      def sync(order, integration)
        client = integration.client
        assert_currency_enabled!(order, client)

        customer_id = client.upsert_customer(CustomerPayload.new(order).to_h)
        order.set_metafield(Metafields::ORDER_CUSTOMER_CODE, customer_id)

        invoice_number = client.create_invoice(invoice_envelope(order, integration, customer_id))
        order.set_metafield(Metafields::ORDER_INVOICE_NUMBER, invoice_number)

        record_payment(order, integration, client, invoice_number) if order.paid?

        order.set_metafield(Metafields::ORDER_SYNCED_AT, Time.current)
        order.set_metafield(Metafields::ORDER_SYNC_ERROR, nil)
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
      # state. Keys are emitted in WSDL `<s:sequence>` order — Savon serialises a
      # Hash body in insertion order, and a .NET ASMX endpoint enforcing that
      # sequence drops or mis-binds an out-of-order element rather than raising.
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
      # - `UseCustomDeliveryAddress`: `false` — no delivery address override is
      #   sent, so this stays off.
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
          "SuppressTotal" => 0,
          "ProjectID" => 0,
          "CurrencyCode" => payload["CurrencyCode"],
          "ExchangeRate" => BigDecimal(1),
          "Lines" => payload["Lines"],
          "NetAmount" => payload["NetAmount"],
          "VATAmount" => payload["VATAmount"],
          "AmountPaid" => order.paid? ? order.total : BigDecimal(0),
          "UseCustomDeliveryAddress" => false,
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
