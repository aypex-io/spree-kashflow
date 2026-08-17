# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow::InvoicePayload do
  subject(:payload) { described_class.new(order, integration: integration) }

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
  let(:reduced_category) { create(:tax_category, name: "Reduced") }

  let!(:standard_rate) do
    create(:tax_rate, zone: zone, tax_category: standard_category, amount: 0.20, included_in_price: true)
  end

  let!(:reduced_rate) do
    create(:tax_rate, zone: zone, tax_category: reduced_category, amount: 0.05, included_in_price: true)
  end

  let(:standard_product) { create(:product, price: 60, tax_category: standard_category) }
  let(:reduced_product) { create(:product, price: 63, tax_category: reduced_category) }

  let(:order) do
    order = create(:order_with_line_items, store: store, currency: "USD", line_items_count: 0, ship_address: create(:address))
    create(:line_item, order: order, variant: standard_product.master, price: 60, quantity: 1, currency: "USD")
    create(:line_item, order: order, variant: reduced_product.master, price: 63, quantity: 1, currency: "USD")
    order.reload
    order.update_with_updater!
    order.reload
  end

  def line_item_for(product)
    order.line_items.detect { |li| li.variant_id == product.master.id }
  end

  describe "#lines" do
    it "produces one line per line item plus one shipping line" do
      expect(payload.lines.length).to eq(order.line_items.length + order.shipments.length)
    end

    it "sets Rate net of both VAT and discount for a VAT-inclusive line" do
      promotion = create(:promotion, store: store, name: "Twelve off")
      Spree::Promotion::Actions::CreateItemAdjustments.create!(
        promotion: promotion,
        calculator: Spree::Calculator::FlatRate.new(preferred_amount: 12, preferred_currency: "USD")
      )
      promotion.actions.each { |action| action.perform(order: order, promotion: promotion) }
      order.reload
      order.update_with_updater!
      order.reload

      line_item = line_item_for(standard_product)
      discounted_gross = line_item.amount + line_item.promo_total
      expected_net_total = discounted_gross - line_item.included_tax_total
      expected_rate = (expected_net_total / line_item.quantity).round(4)

      line = payload.lines.find { |l| l["Description"].start_with?(line_item.name) }
      expect(line["Rate"]).to eq(expected_rate)
    end

    it "sets VatAmount to the line's included_tax_total" do
      line_item = line_item_for(standard_product)

      line = payload.lines.find { |l| l["Description"] == line_item.name }
      expect(line["VatAmount"]).to eq(line_item.included_tax_total)
    end

    it "sets VatRate to 20 for the 20%-inclusive line" do
      line_item = line_item_for(standard_product)

      line = payload.lines.find { |l| l["Description"] == line_item.name }
      expect(line["VatRate"]).to eq(BigDecimal(20))
    end

    it "sets VatRate to 5 for the 5%-inclusive line in the same order" do
      line_item = line_item_for(reduced_product)

      line = payload.lines.find { |l| l["Description"] == line_item.name }
      expect(line["VatRate"]).to eq(BigDecimal(5))
    end

    it "names the promotion in the description when one applies" do
      promotion = create(:promotion, store: store, name: "Ten off", code: "TENOFF")
      Spree::Promotion::Actions::CreateItemAdjustments.create!(
        promotion: promotion,
        calculator: Spree::Calculator::FlatRate.new(preferred_amount: 10, preferred_currency: "USD")
      )
      promotion.actions.each { |action| action.perform(order: order, promotion: promotion) }
      order.reload
      order.update_with_updater!
      order.reload

      line_item = line_item_for(standard_product)
      line = payload.lines.find { |l| l["Description"].start_with?(line_item.name) }
      expect(line["Description"]).to eq("#{line_item.name} (#{promotion.code} applied)")
    end

    it "does not name a promotion in the description when none applies" do
      line_item = line_item_for(standard_product)

      line = payload.lines.find { |l| l["Description"].start_with?(line_item.name) }
      expect(line["Description"]).to eq(line_item.name)
    end

    it "sets ChargeType to the sales nominal code on product lines" do
      line_item = line_item_for(standard_product)

      line = payload.lines.find { |l| l["Description"] == line_item.name }
      expect(line["ChargeType"]).to eq(4000)
    end

    it "sets ChargeType to the shipping nominal code on the shipping line" do
      shipping_line = payload.lines.find { |l| l["Description"] == "Shipping" }
      expect(shipping_line["ChargeType"]).to eq(4040)
    end

    context "with a quantity-3 line whose net total is 10.00" do
      let(:untaxed_product) { create(:product, price: 4, tax_category: nil) }
      let(:order) do
        order = create(:order_with_line_items, store: store, currency: "USD", line_items_count: 0, ship_address: create(:address))
        create(:line_item, order: order, variant: untaxed_product.master, price: 4, quantity: 3, currency: "USD")
        order.reload
        order.update_with_updater!
        order.reload
      end

      before do
        promotion = create(:promotion, store: store, name: "Two off")
        Spree::Promotion::Actions::CreateItemAdjustments.create!(
          promotion: promotion,
          calculator: Spree::Calculator::FlatRate.new(preferred_amount: 2, preferred_currency: "USD")
        )
        promotion.actions.each { |action| action.perform(order: order, promotion: promotion) }
        order.reload
        order.update_with_updater!
        order.reload
      end

      it "produces Rate 3.3333" do
        line_item = order.line_items.first
        expect(line_item.included_tax_total).to eq(BigDecimal(0))
        expect(line_item.amount + line_item.promo_total).to eq(BigDecimal("10.00"))

        line = payload.lines.find { |l| l["Description"].start_with?(line_item.name) }
        expect(line["Rate"]).to eq(BigDecimal("3.3333"))
      end

      it "still passes the guard in #to_h" do
        expect { payload.to_h }.not_to raise_error
      end
    end
  end

  describe "#to_h" do
    it "sets CurrencyCode to the order's currency" do
      expect(payload.to_h["CurrencyCode"]).to eq("USD")
    end

    context "when a line cannot reconcile Rate * Quantity against its net total" do
      let(:unreconcilable_line_item) do
        instance_double(
          Spree::LineItem,
          name: "Unreconcilable widget",
          amount: BigDecimal("1.00"),
          promo_total: BigDecimal(0),
          included_tax_total: BigDecimal(0),
          quantity: 1_000_000,
          adjustments: Spree::Adjustment.none
        )
      end
      let(:order) do
        instance_double(
          Spree::Order,
          line_items: [unreconcilable_line_item],
          shipments: [],
          currency: "USD",
          total: BigDecimal("1.00")
        )
      end

      it "raises TotalMismatchError and returns no payload" do
        expect { payload.to_h }.to raise_error(Spree::Kashflow::TotalMismatchError)
      end
    end

    context "when the assembled total diverges from order.total" do
      let(:order) do
        order = create(:order_with_line_items, store: store, currency: "USD", line_items_count: 0, ship_address: create(:address))
        create(:line_item, order: order, variant: standard_product.master, price: 60, quantity: 1, currency: "USD")
        order.reload
        order.update_with_updater!
        order.reload
      end

      before do
        promotion = create(:promotion, store: store, name: "Order-level fiver off")
        Spree::Promotion::Actions::CreateAdjustment.create!(
          promotion: promotion,
          calculator: Spree::Calculator::FlatRate.new(preferred_amount: 5, preferred_currency: "USD")
        )
        promotion.actions.each { |action| action.perform(order: order) }
        order.reload
        order.update_with_updater!
        order.reload
      end

      it "raises TotalMismatchError" do
        expect { payload.to_h }.to raise_error(Spree::Kashflow::TotalMismatchError)
      end
    end
  end
end
