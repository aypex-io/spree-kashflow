# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Posts a refund to KashFlow as a credit note, linked to the original invoice
    # via `applyCreditNoteToInvoice`.
    #
    # A resumable state machine, the same way as {SyncOrderJob}: posting the
    # credit note and linking it to the original invoice are two separate calls,
    # each with its own marker written the instant it succeeds
    # ({Metafields::REFUND_CREDIT_NOTE_NUMBER} and
    # {Metafields::REFUND_CREDIT_NOTE_LINKED_AT}), and each guarded independently
    # in {#sync}. A rerun resumes at the first unfinished step.
    #
    class SyncRefundJob < Spree::BaseJob
      # See {SyncOrderJob}: bad credentials will never succeed on retry.
      discard_on Spree::Kashflow::AuthenticationError

      # See {SyncOrderJob}: a business rejection does not become acceptance on the
      # 25th attempt, and {Metafields::ORDER_SYNC_ERROR} already records it.
      discard_on Spree::Kashflow::ApiError

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

        return if credit_note_posted?(refund) && credit_note_linked?(refund)

        sync(refund, order, integration)
      rescue Spree::Kashflow::Error => e
        Metafields.write(order, Metafields::ORDER_SYNC_ERROR, e.message)
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

        # Written the instant `create_invoice` returns, before the link call is
        # attempted. A credit note is a ledger document: creating it must be
        # at-most-once, because a duplicate permanently overstates the credit and
        # nothing in KashFlow flags it. Linking one that already exists is a
        # separate, re-attemptable step. Writing this marker last — so that a
        # failed link left the refund "unposted" — is precisely what made a retry
        # post a *second* credit note, manufacturing the orphan the guard above
        # exists to prevent rather than avoiding it.
        unless credit_note_posted?(refund)
          posted_number = client.create_invoice(credit_note_envelope(refund, order, integration, customer_id))
          Metafields.write(refund, Metafields::REFUND_CREDIT_NOTE_NUMBER, posted_number)
        end

        # Guarded separately, and by its own marker rather than by the credit note
        # number: re-applying a link is unverified against a live account, so it
        # is never attempted twice.
        return if credit_note_linked?(refund)

        invoice_number = order.get_metafield(CreditNotePayload::INVOICE_NUMBER_METAFIELD_KEY).value.to_i
        client.apply_credit_note(credit_note_number: credit_note_number(refund), invoice_number: invoice_number)
        Metafields.write(refund, Metafields::REFUND_CREDIT_NOTE_LINKED_AT, Time.current)
      end

      ##
      # @param refund [Spree::Refund]
      # @return [TrueClass, FalseClass] whether the credit note has already been
      #   posted to KashFlow for this refund
      #
      def credit_note_posted?(refund)
        refund.has_metafield?(Metafields::REFUND_CREDIT_NOTE_NUMBER)
      end

      ##
      # @param refund [Spree::Refund]
      # @return [TrueClass, FalseClass] whether the credit note has already been
      #   linked to the original invoice
      #
      def credit_note_linked?(refund)
        refund.has_metafield?(Metafields::REFUND_CREDIT_NOTE_LINKED_AT)
      end

      ##
      # @param refund [Spree::Refund]
      # @return [Integer, nil] the KashFlow credit note number recorded on the refund
      #
      def credit_note_number(refund)
        refund.get_metafield(Metafields::REFUND_CREDIT_NOTE_NUMBER)&.value&.to_i
      end

      ##
      # Wraps {CreditNotePayload#to_h}'s fields in the same WSDL `Invoice` envelope
      # {SyncOrderJob#invoice_envelope} builds — a credit note is posted through
      # the same `InsertInvoice_TypeDefined` operation as a real invoice, so it
      # needs the same `minOccurs="1"` fields. `Paid`/`AmountPaid` are `0`: a
      # credit note is not itself a payment, it is linked to the original invoice
      # separately via `applyCreditNoteToInvoice`. See
      # {SyncOrderJob#invoice_envelope} for the rationale behind the
      # `ArrayOfInvoiceLine` wrapper around `Lines` and the CIS reverse-charge
      # trio (UK Construction Industry Scheme fields, structurally required but
      # not applicable to this integration).
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
          "Lines" => {"InvoiceLine" => payload["Lines"]},
          "NetAmount" => payload["NetAmount"],
          "VATAmount" => payload["VATAmount"],
          "AmountPaid" => BigDecimal(0),
          "CISRCNetAmount" => 0,
          "CISRCVatAmount" => 0,
          "IsCISReverseCharge" => false
        }
      end
    end
  end
end
