# frozen_string_literal: true

##
# The only decorator in this gem, and it must not grow.
#
# Spree 5.6 publishes no `refund.created` event, and the returns flow
# (`reimbursement.reimbursed`, handled by
# {Spree::Kashflow::ReimbursementSubscriber}) does not cover an admin issuing
# an ad-hoc refund directly against a payment — the most common manual path.
# Left unmirrored, that path would reintroduce the ledger drift KashFlow
# credit notes exist to prevent, so this decorator enqueues
# {Spree::Kashflow::SyncRefundJob} on every refund. It does nothing else:
# no client, no payload building, no integration lookup — the job already
# no-ops when no active integration exists.
#
# If Spree ever adds a `refund.created` event, delete this decorator in
# favour of a `Spree::Kashflow::RefundCreatedSubscriber`.
#
Spree::Refund.class_eval do
  after_create_commit -> { Spree::Kashflow::SyncRefundJob.perform_later(id) }
end
