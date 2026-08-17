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
          UseCustomDeliveryAddress CISRCNetAmount CISRCVatAmount IsCISReverseCharge
        ])
      end

      it "sets the schema-required tail fields to arithmetically neutral defaults" do
        captured = nil
        allow(client).to receive(:create_invoice) { |payload|
          captured = payload
          4321
        }

        described_class.perform_now(refund.id)

        expect(captured.values_at("UseCustomDeliveryAddress", "CISRCNetAmount", "CISRCVatAmount", "IsCISReverseCharge"))
          .to eq([false, 0, 0, false])
      end
    end

    context "when the order has no KashFlow invoice number" do
      it "raises an ApiError instead of posting an orphan credit note" do
        expect { described_class.perform_now(refund.id) }.to raise_error(Spree::Kashflow::ApiError, /invoice number/)
      end
    end
  end
end
