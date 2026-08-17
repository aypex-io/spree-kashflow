# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Spree::Refund decorator" do
  include ActiveJob::TestHelper

  let(:store) { Spree::Store.default }

  let(:order) do
    order = create(:order_with_line_items, store: store, ship_address: create(:address), shipment_cost: 0)
    order.update_with_updater!
    order
  end

  let(:payment) { create(:payment, order: order, amount: order.total, state: "completed") }
  let(:refund_reason) { create(:refund_reason, name: "Customer changed mind") }

  it "enqueues SyncRefundJob with the new refund's id when an ad-hoc refund is created" do
    refund = create(:refund, payment: payment, amount: order.total, reason: refund_reason)

    expect(enqueued_jobs.map { |job| [job["job_class"], job["arguments"]] })
      .to include(["Spree::Kashflow::SyncRefundJob", [refund.id]])
  end
end
