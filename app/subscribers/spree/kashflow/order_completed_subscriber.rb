# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Enqueues {SyncOrderJob} whenever Spree publishes `order.completed`.
    #
    class OrderCompletedSubscriber < Spree::Subscriber
      subscribes_to "order.completed"

      ##
      # @param event [Spree::Event] payload carries the order's prefixed id
      #   under `"id"`
      # @return [void]
      #
      def handle(event)
        order = Spree::Order.find_by_prefix_id(event.payload["id"])
        return if order.nil?

        SyncOrderJob.perform_later(order.id)
      end
    end
  end
end
