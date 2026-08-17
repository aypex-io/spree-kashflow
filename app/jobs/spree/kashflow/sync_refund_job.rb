# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Posts a refund to KashFlow as a credit note, linked to the original invoice
    # via `applyCreditNoteToInvoice`.
    #
    # Idempotent by design, the same way as {SyncOrderJob}: a second run for the
    # same refund is a no-op once the refund carries a
    # {Metafields::REFUND_CREDIT_NOTE_NUMBER} metafield.
    #
    class SyncRefundJob < Spree::BaseJob
      # See {SyncOrderJob}: bad credentials will never succeed on retry.
      discard_on Spree::Kashflow::AuthenticationError

      # See {SyncOrderJob}: KashFlow being briefly unreachable is retry-safe.
      retry_on Spree::Kashflow::TransportError, wait: :polynomially_longer, attempts: 5

      ##
      # @param refund_id [Integer, String] the {Spree::Refund} id
      # @return [void]
      # @raise [Spree::Kashflow::Error] any subclass raised while posting; the
      #   message is written to the order's {Metafields::ORDER_SYNC_ERROR} first
      #
      def perform(refund_id)
        refund = Spree::Refund.find_by(id: refund_id)
        return if refund.nil?

        order = refund.order
        integration = Spree::Integrations::Kashflow.active.find_by(store: order.store)
        return if integration.nil?

        return if refund.has_metafield?(Metafields::REFUND_CREDIT_NOTE_NUMBER)

        sync(refund, order, integration)
      rescue Spree::Kashflow::Error => e
        order.set_metafield(Metafields::ORDER_SYNC_ERROR, e.message)
        raise
      end

      private

      ##
      # A refund on an order that never synced would post a credit note with no
      # `CustomerReference` for KashFlow to link it to
      # ({CreditNotePayload#to_h} returns `nil` there) — an orphan
      # `applyCreditNoteToInvoice` cannot resolve. Refused up front rather than
      # posted and left dangling.
      #
      # @param refund [Spree::Refund]
      # @param order [Spree::Order]
      # @param integration [Spree::Integrations::Kashflow]
      # @return [void]
      # @raise [Spree::Kashflow::ApiError] when the order has no KashFlow invoice
      #   number yet
      #
      def sync(refund, order, integration)
        unless order.has_metafield?(CreditNotePayload::INVOICE_NUMBER_METAFIELD_KEY)
          raise Spree::Kashflow::ApiError,
            "Order #{order.number.inspect} has no KashFlow invoice number; refusing to post an orphan credit note for refund #{refund.id}"
        end

        client = integration.client
        customer_id = client.upsert_customer(CustomerPayload.new(order).to_h)

        credit_note_number = client.create_invoice(credit_note_envelope(refund, order, integration, customer_id))
        refund.set_metafield(Metafields::REFUND_CREDIT_NOTE_NUMBER, credit_note_number)

        invoice_number = order.get_metafield(CreditNotePayload::INVOICE_NUMBER_METAFIELD_KEY).value.to_i
        client.apply_credit_note(credit_note_number: credit_note_number, invoice_number: invoice_number)
      end

      ##
      # Wraps {CreditNotePayload#to_h}'s fields in the same WSDL `Invoice` envelope
      # {SyncOrderJob#invoice_envelope} builds — a credit note is posted through
      # the same `InsertInvoice_TypeDefined` operation as a real invoice, so it
      # needs the same `minOccurs="1"` fields. `Paid`/`AmountPaid` are `0`: a
      # credit note is not itself a payment, it is linked to the original invoice
      # separately via `applyCreditNoteToInvoice`. See
      # {SyncOrderJob#invoice_envelope} for the rationale behind
      # `UseCustomDeliveryAddress` and the CIS reverse-charge trio (UK
      # Construction Industry Scheme fields, structurally required but not
      # applicable to this integration).
      #
      # @param refund [Spree::Refund]
      # @param order [Spree::Order]
      # @param integration [Spree::Integrations::Kashflow]
      # @param customer_id [Integer] the id returned by `Client#upsert_customer`
      # @return [Hash{String => Object}] a KashFlow `Invoice` structure, in WSDL
      #   sequence order
      #
      def credit_note_envelope(refund, order, integration, customer_id)
        payload = CreditNotePayload.new(refund, integration: integration).to_h
        credit_note_date = refund.created_at || Time.current

        {
          "InvoiceDBID" => 0,
          "InvoiceNumber" => 0,
          "InvoiceDate" => credit_note_date,
          "DueDate" => credit_note_date,
          "CustomerID" => customer_id,
          "Paid" => 0,
          "CustomerReference" => payload["CustomerReference"],
          "SuppressTotal" => 0,
          "ProjectID" => 0,
          "CurrencyCode" => payload["CurrencyCode"],
          "ExchangeRate" => BigDecimal(1),
          "Lines" => payload["Lines"],
          "NetAmount" => payload["NetAmount"],
          "VATAmount" => payload["VATAmount"],
          "AmountPaid" => BigDecimal(0),
          "UseCustomDeliveryAddress" => false,
          "CISRCNetAmount" => 0,
          "CISRCVatAmount" => 0,
          "IsCISReverseCharge" => false
        }
      end
    end
  end
end
