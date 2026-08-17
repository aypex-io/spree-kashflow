# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow::OrderCompletedSubscriber do
  include ActiveJob::TestHelper

  let(:order) do
    order = create(:order_with_line_items, ship_address: create(:address), shipment_cost: 0)
    order.update_with_updater!
    order
  end

  it "enqueues SyncOrderJob exactly once when the order completes" do
    expect {
      perform_enqueued_jobs(only: Spree::Events::SubscriberJob) { order.finalize! }
    }.to have_enqueued_job(Spree::Kashflow::SyncOrderJob).with(order.id).exactly(1).times
  end
end
