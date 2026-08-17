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
    # be pre-seeded, but the auto-created definition takes `display_on`'s default of
    # `"both"`, which would make a KashFlow invoice number — and raw KashFlow fault
    # text in {ORDER_SYNC_ERROR} — storefront-visible by accident. Every write this
    # gem makes therefore goes through {.write}, which seeds the definition as
    # `"back_end"` first. These are internal accounting-sync markers; nothing here is
    # ever meant for a customer.
    #
    module Metafields
      # @return [String] order metafield; the KashFlow invoice number. Written
      #   immediately after `InsertInvoice_TypeDefined` returns, before any
      #   follow-on call, so a later failure can never cause the invoice to be
      #   posted twice. Its presence is the per-step guard {SyncOrderJob} uses to
      #   skip re-posting the invoice, and it is the identifier
      #   {CreditNotePayload} carries as `CustomerReference` when a refund is
      #   posted as a credit note.
      ORDER_INVOICE_NUMBER = "kashflow.invoice_number"

      # @return [String] order metafield; the timestamp at which the order's
      #   payment was recorded against the KashFlow invoice. Written immediately
      #   after `InsertInvoicePayment` succeeds, and checked separately from
      #   {ORDER_INVOICE_NUMBER} so a retry resumes at the payment step instead of
      #   re-posting the invoice or skipping the job wholesale.
      ORDER_PAYMENT_RECORDED_AT = "kashflow.payment_recorded_at"

      # @return [String] order metafield; the KashFlow customer id returned by
      #   `Client#upsert_customer`.
      ORDER_CUSTOMER_CODE = "kashflow.customer_code"

      # @return [String] order metafield; the timestamp of the last successful sync.
      ORDER_SYNCED_AT = "kashflow.synced_at"

      # @return [String] order metafield; the message of the last sync failure.
      #   Cleared (destroyed) on the next successful sync.
      ORDER_SYNC_ERROR = "kashflow.sync_error"

      # @return [String] refund metafield; the KashFlow credit note (invoice) number.
      #   Written immediately after the credit note is posted, before the link
      #   call, so a failing link can never cause a second credit note. Its
      #   presence is the per-step guard {SyncRefundJob} uses to skip re-posting.
      REFUND_CREDIT_NOTE_NUMBER = "kashflow.credit_note_number"

      # @return [String] refund metafield; the timestamp at which the credit note
      #   was linked to the original invoice via `applyCreditNoteToInvoice`.
      #   Checked separately from {REFUND_CREDIT_NOTE_NUMBER} so a retry re-runs
      #   only the link step. Re-applying a link is unverified against a live
      #   account, so this marker exists to avoid attempting it twice.
      REFUND_CREDIT_NOTE_LINKED_AT = "kashflow.credit_note_linked_at"

      # @return [String] the `display_on` value every definition this gem owns
      #   is seeded with: admin-only, never rendered on the storefront.
      DISPLAY_ON = "back_end"

      ##
      # Writes one of this gem's metafields, seeding its backing
      # `Spree::MetafieldDefinition` as {DISPLAY_ON} first so Spree's auto-create
      # path never gets to default it to `"both"`.
      #
      # Idempotent and cheap: after the first write per key the seed is a single
      # indexed lookup. Deliberately not a boot-time initializer or a migration —
      # the gem ships neither, and a definition seeded at boot would need the
      # database up before the app could load.
      #
      # @param record [#set_metafield] the {Spree::Order} or {Spree::Refund} to write to
      # @param key [String] one of this module's `"namespace.key"` constants
      # @param value [Object, nil] the value to store; `nil` clears the metafield
      # @return [void]
      #
      # @example
      #   Spree::Kashflow::Metafields.write(order, Spree::Kashflow::Metafields::ORDER_INVOICE_NUMBER, 4471)
      #
      def self.write(record, key, value)
        ensure_definition!(record, key)
        record.set_metafield(key, value)
      end

      ##
      # @param record [ActiveRecord::Base] the resource the definition belongs to
      # @param key [String] a `"namespace.key"` string
      # @return [Spree::MetafieldDefinition] the seeded (or already-present) definition
      #
      def self.ensure_definition!(record, key)
        namespace, definition_key = key.split(".", 2)

        Spree::MetafieldDefinition.find_or_create_by!(
          namespace: namespace,
          key: definition_key,
          resource_type: record.class.name
        ) { |definition| definition.display_on = DISPLAY_ON }
      end
    end
  end
end
