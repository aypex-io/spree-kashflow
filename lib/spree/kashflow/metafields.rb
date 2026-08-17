# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # The Spree metafield keys ({Spree::Metafields#set_metafield} /
    # {Spree::Metafields#get_metafield} "namespace.key" strings) this gem reads and
    # writes. Centralised here so call sites never repeat the string literal, and so
    # a later task (or the README) has one place to look up the whole table.
    #
    # `Spree::Metafields#set_metafield` auto-creates its backing
    # `Spree::MetafieldDefinition` the first time a `"namespace.key"` string is used
    # (`Spree::Metafields#resolve_metafield_definition_id_from_string`,
    # spree_core-5.6.1 `app/models/concerns/spree/metafields.rb:222`) — confirmed
    # empirically against the dummy app (see Task 7's report). No definition needs to
    # be pre-seeded.
    #
    module Metafields
      # @return [String] order metafield; the KashFlow invoice number. Set once the
      #   order is posted; its presence is the idempotency check {SyncOrderJob} uses
      #   to refuse re-posting, and the identifier {CreditNotePayload} carries as
      #   `CustomerReference` when a refund is posted as a credit note.
      ORDER_INVOICE_NUMBER = "kashflow.invoice_number"

      # @return [String] order metafield; the KashFlow customer id returned by
      #   `Client#upsert_customer`.
      ORDER_CUSTOMER_CODE = "kashflow.customer_code"

      # @return [String] order metafield; the timestamp of the last successful sync.
      ORDER_SYNCED_AT = "kashflow.synced_at"

      # @return [String] order metafield; the message of the last sync failure.
      #   Cleared (destroyed) on the next successful sync.
      ORDER_SYNC_ERROR = "kashflow.sync_error"

      # @return [String] refund metafield; the KashFlow credit note (invoice) number.
      #   Set once the refund is posted; its presence is the idempotency check
      #   {SyncRefundJob} uses to refuse re-posting.
      REFUND_CREDIT_NOTE_NUMBER = "kashflow.credit_note_number"
    end
  end
end
