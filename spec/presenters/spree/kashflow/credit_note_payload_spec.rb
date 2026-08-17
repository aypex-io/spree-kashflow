# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow::CreditNotePayload do
  subject(:payload) { described_class.new(refund, integration: integration) }

  let(:integration) do
    Spree::Integrations::Kashflow.new(
      preferred_username: "kashflow-user",
      preferred_password: "kashflow-pass",
      preferred_sales_nominal_code: 4000,
      preferred_shipping_nominal_code: 4040,
      preferred_bank_account_id: 1,
      preferred_payment_method_id: 1
    )
  end

  let(:store) { Spree::Store.default }
  let(:zone) { create(:global_zone) }
  let(:standard_category) { create(:tax_category, name: "Standard") }

  let!(:standard_rate) do
    create(:tax_rate, zone: zone, tax_category: standard_category, amount: 0.20, included_in_price: true)
  end

  let(:standard_product) { create(:product, price: 60, tax_category: standard_category) }

  let(:order) do
    order = create(:order_with_line_items, store: store, currency: "USD", line_items_count: 0, ship_address: create(:address))
    create(:line_item, order: order, variant: standard_product.master, price: 60, quantity: 1, currency: "USD")
    order.reload
    order.update_with_updater!
    order.reload
    order.set_metafield("kashflow.invoice_number", "INV-00042")
    order.reload
  end

  let(:refund_reason) { create(:refund_reason, name: "Customer changed mind") }

  let(:payment) { create(:payment, order: order, amount: order.total, state: "completed") }

  def build_refund(amount)
    create(:refund, payment: payment, amount: amount, reason: refund_reason)
  end

  describe "#to_h" do
    context "with a full refund" do
      let(:refund) { build_refund(order.total) }

      it "mirrors the invoice lines with negated Rate" do
        invoice_lines = Spree::Kashflow::InvoicePayload.new(order, integration: integration).to_h["Lines"]
        expect(payload.to_h["Lines"].map { |l| l["Rate"] }).to eq(invoice_lines.map { |l| -l["Rate"] })
      end

      it "mirrors the invoice lines with negated VatAmount" do
        invoice_lines = Spree::Kashflow::InvoicePayload.new(order, integration: integration).to_h["Lines"]
        expect(payload.to_h["Lines"].map { |l| l["VatAmount"] }).to eq(invoice_lines.map { |l| -l["VatAmount"] })
      end

      it "keeps Quantity positive on every line" do
        expect(payload.to_h["Lines"].map { |l| l["Quantity"] }).to all(be > 0)
      end

      it "carries the original invoice number as CustomerReference" do
        expect(payload.to_h["CustomerReference"]).to eq("INV-00042")
      end
    end

    context "with a partial refund" do
      let(:refund) { build_refund(BigDecimal("24.00")) }

      it "produces exactly one line" do
        expect(payload.to_h["Lines"].length).to eq(1)
      end

      it "sets the line's Rate to the negative net portion of the refund" do
        blended_rate = order.included_tax_total / (order.total - order.included_tax_total)
        expected_net = (refund.amount / (1 + blended_rate)).round(2)
        expect(payload.to_h["Lines"].first["Rate"]).to eq(-expected_net)
      end

      it "keeps the line's Quantity positive" do
        expect(payload.to_h["Lines"].first["Quantity"]).to be > 0
      end

      it "sets ChargeType to the sales nominal code" do
        expect(payload.to_h["Lines"].first["ChargeType"]).to eq(4000)
      end

      it "names the refund reason in the line's Description" do
        expect(payload.to_h["Lines"].first["Description"]).to include("Customer changed mind")
      end

      it "carries the original invoice number as CustomerReference" do
        expect(payload.to_h["CustomerReference"]).to eq("INV-00042")
      end
    end
  end
end
