# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow::ReimbursementSubscriber do
  include ActiveJob::TestHelper

  let(:reimbursement) { create(:reimbursement) }

  it "enqueues SyncRefundJob for the reimbursement's refund" do
    perform_enqueued_jobs(only: Spree::Events::SubscriberJob) { reimbursement.perform! }
    refund_id = reimbursement.refunds.sole.id

    expect(enqueued_jobs.map { |job| [job["job_class"], job["arguments"]] })
      .to include(["Spree::Kashflow::SyncRefundJob", [refund_id]])
  end

  it "does enqueue SyncRefundJob twice for the same refund, once from the decorator and once from this subscriber" do
    perform_enqueued_jobs(only: Spree::Events::SubscriberJob) { reimbursement.perform! }
    refund_id = reimbursement.refunds.sole.id

    enqueue_count = enqueued_jobs.count { |job| job["job_class"] == "Spree::Kashflow::SyncRefundJob" && job["arguments"] == [refund_id] }

    expect(enqueue_count).to eq(2)
  end

  # The double enqueue above is real: Spree::Refund#after_create_commit (the
  # gem's one decorator) fires when the reimbursement's refund is saved, and
  # this subscriber fires separately once the reimbursement transitions to
  # `reimbursed`. Rather than stop at counting enqueues, this proves the
  # outcome that actually matters: SyncRefundJob's own idempotency
  # (see app/jobs/spree/kashflow/sync_refund_job.rb) makes running both a
  # no-op past the first — only one credit note is ever posted to KashFlow.
  context "when both enqueued SyncRefundJob runs are performed" do
    let(:client) do
      instance_double(
        Spree::Kashflow::Client,
        currencies: [{code: reimbursement.order.currency, id: 1}],
        upsert_customer: 555,
        create_invoice: 4321,
        apply_credit_note: true
      )
    end

    let(:integration) do
      Spree::Integrations::Kashflow.create!(
        store: reimbursement.order.store,
        active: true,
        preferred_username: "kashflow-user",
        preferred_password: "kashflow-pass",
        preferred_sales_nominal_code: 4000,
        preferred_shipping_nominal_code: 4040,
        preferred_bank_account_id: 1,
        preferred_payment_method_id: 1
      )
    end

    before do
      allow(Spree::Kashflow::Client).to receive(:new).and_return(client)
      integration
      reimbursement.order.set_metafield(Spree::Kashflow::Metafields::ORDER_INVOICE_NUMBER, "98765")
    end

    it "posts only one credit note to KashFlow" do
      perform_enqueued_jobs(only: Spree::Events::SubscriberJob) { reimbursement.perform! }
      perform_enqueued_jobs(only: Spree::Kashflow::SyncRefundJob)

      expect(client).to have_received(:create_invoice).once
    end
  end
end
