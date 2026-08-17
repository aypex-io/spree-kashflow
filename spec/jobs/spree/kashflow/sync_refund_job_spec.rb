# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow::SyncRefundJob do
  let(:client) do
    instance_double(
      Spree::Kashflow::Client,
      currencies: [{code: "USD", id: 1}],
      upsert_customer: 555,
      create_invoice: 4321,
      apply_credit_note: true
    )
  end

  let(:store) { Spree::Store.default }

  let(:integration) do
    Spree::Integrations::Kashflow.create!(
      store: store,
      active: true,
      preferred_username: "kashflow-user",
      preferred_password: "kashflow-pass",
      preferred_sales_nominal_code: 4000,
      preferred_shipping_nominal_code: 4040,
      preferred_bank_account_id: 1,
      preferred_payment_method_id: 1
    )
  end

  let(:product) { create(:product, price: 10, tax_category: nil) }

  let(:order) do
    order = create(:order_with_line_items, store: store, currency: "USD", line_items_count: 0, ship_address: create(:address), shipment_cost: 0)
    create(:line_item, order: order, variant: product.master, price: 10, quantity: 1, currency: "USD")
    order.reload
    order.update_with_updater!
    order.reload
  end

  let(:refund_reason) { create(:refund_reason, name: "Customer changed mind") }
  let(:payment) { create(:payment, order: order, amount: order.total, state: "completed") }
  let(:refund) { create(:refund, payment: payment, amount: order.total, reason: refund_reason) }

  before do
    allow(Spree::Kashflow::Client).to receive(:new).and_return(client)
    integration
  end

  describe "#perform" do
    context "when the order already has a KashFlow invoice number" do
      before { order.set_metafield(Spree::Kashflow::Metafields::ORDER_INVOICE_NUMBER, "98765") }

      it "stores the KashFlow credit note number on the refund" do
        described_class.perform_now(refund.id)

        expect(refund.reload.get_metafield(Spree::Kashflow::Metafields::REFUND_CREDIT_NOTE_NUMBER).value).to eq("4321")
      end

      it "does not post a second credit note on a second run" do
        described_class.perform_now(refund.id)
        described_class.perform_now(refund.id)

        expect(client).to have_received(:create_invoice).once
      end

      it "links the credit note to the original invoice" do
        described_class.perform_now(refund.id)

        expect(client).to have_received(:apply_credit_note).with(credit_note_number: 4321, invoice_number: 98765)
      end

      it "records the link step separately from the credit note number" do
        described_class.perform_now(refund.id)

        expect(refund.reload.has_metafield?(Spree::Kashflow::Metafields::REFUND_CREDIT_NOTE_LINKED_AT)).to be(true)
      end

      # Creating a credit note must be at-most-once, exactly as for an invoice.
      # Writing the number only after `apply_credit_note` succeeded meant a
      # failed link guaranteed the retry posted a *second* credit note —
      # manufacturing the orphan the job's up-front guard exists to prevent.
      context "and linking the credit note fails" do
        before do
          allow(client).to receive(:apply_credit_note)
            .and_raise(Spree::Kashflow::ApiError, "invoice 98765 is already fully credited")
        end

        it "still records the credit note number KashFlow assigned" do
          described_class.perform_now(refund.id)

          expect(refund.reload.get_metafield(Spree::Kashflow::Metafields::REFUND_CREDIT_NOTE_NUMBER).value).to eq("4321")
        end

        it "does not mark the credit note as linked" do
          described_class.perform_now(refund.id)

          expect(refund.reload.has_metafield?(Spree::Kashflow::Metafields::REFUND_CREDIT_NOTE_LINKED_AT)).to be(false)
        end

        it "posts the credit note exactly once across a retry" do
          2.times { described_class.perform_now(refund.id) }

          expect(client).to have_received(:create_invoice).once
        end

        it "retries only the failed link step" do
          2.times { described_class.perform_now(refund.id) }

          expect(client).to have_received(:apply_credit_note).twice
        end

        it "resumes at the link step and completes when KashFlow accepts it" do
          described_class.perform_now(refund.id)
          allow(client).to receive(:apply_credit_note).and_return(true)

          described_class.perform_now(refund.id)

          expect(client).to have_received(:create_invoice).once
          expect(refund.reload.has_metafield?(Spree::Kashflow::Metafields::REFUND_CREDIT_NOTE_LINKED_AT)).to be(true)
        end
      end

      it "seeds the refund metafield definition as back-end only" do
        described_class.perform_now(refund.id)

        definition = Spree::MetafieldDefinition.find_by(
          namespace: "kashflow", key: "credit_note_number", resource_type: "Spree::Refund"
        )
        expect(definition.display_on).to eq("back_end")
      end

      it "emits credit note envelope keys in WSDL sequence order" do
        captured = nil
        allow(client).to receive(:create_invoice) { |payload|
          captured = payload
          4321
        }

        described_class.perform_now(refund.id)

        expect(captured.keys).to eq(%w[
          InvoiceDBID InvoiceNumber InvoiceDate DueDate CustomerID Paid CustomerReference
          SuppressTotal ProjectID CurrencyCode ExchangeRate Lines NetAmount VATAmount AmountPaid
          CISRCNetAmount CISRCVatAmount IsCISReverseCharge
        ])
      end

      it "wraps the credit note lines in the ArrayOfInvoiceLine element the WSDL declares" do
        captured = nil
        allow(client).to receive(:create_invoice) { |payload|
          captured = payload
          4321
        }

        described_class.perform_now(refund.id)

        expect(captured["Lines"].keys).to eq(["InvoiceLine"])
        expect(captured["Lines"]["InvoiceLine"]).to all(include("Rate"))
      end

      it "sets the schema-required tail fields to arithmetically neutral defaults" do
        captured = nil
        allow(client).to receive(:create_invoice) { |payload|
          captured = payload
          4321
        }

        described_class.perform_now(refund.id)

        expect(captured.values_at("CISRCNetAmount", "CISRCVatAmount", "IsCISReverseCharge"))
          .to eq([0, 0, false])
      end
    end

    # As in SyncOrderJob, an ApiError is now discarded rather than re-raised —
    # a rejection does not become acceptance on the 25th attempt, and
    # kashflow.sync_error is the operator-visible record. The refusal itself is
    # unchanged and still asserted, via that metafield.
    context "when the order has no KashFlow invoice number" do
      it "does not post an orphan credit note" do
        described_class.perform_now(refund.id)

        expect(client).not_to have_received(:create_invoice)
      end

      it "records the refusal on the order rather than retrying it" do
        expect { described_class.perform_now(refund.id) }.not_to raise_error

        expect(order.reload.get_metafield(Spree::Kashflow::Metafields::ORDER_SYNC_ERROR).value)
          .to match(/invoice number/)
      end
    end
  end
end
