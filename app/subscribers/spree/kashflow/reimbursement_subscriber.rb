# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Enqueues {SyncRefundJob} for each refund on a reimbursement whenever
    # Spree publishes `reimbursement.reimbursed`.
    #
    class ReimbursementSubscriber < Spree::Subscriber
      subscribes_to "reimbursement.reimbursed"

      ##
      # @param event [Spree::Event] payload carries the reimbursement's
      #   prefixed id under `"id"`
      # @return [void]
      #
      def handle(event)
        reimbursement = Spree::Reimbursement.find_by_prefix_id(event.payload["id"])
        return if reimbursement.nil?

        reimbursement.refunds.each { |refund| SyncRefundJob.perform_later(refund.id) }
      end
    end
  end
end
