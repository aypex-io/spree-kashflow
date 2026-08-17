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
      # Upcased because the annotation now comes from `Promotion#name_for_order`,
      # which upcases; `#code` is nil for automatic and multi-code promotions.
      expect(line["Description"]).to eq("#{line_item.name} (#{promotion.code.upcase} applied)")
    end

    it "names an automatic promotion in the description, which carries no code" do
      promotion = create(:promotion, store: store, name: "Autumn sale", kind: "automatic")
      Spree::Promotion::Actions::CreateItemAdjustments.create!(
        promotion: promotion,
        calculator: Spree::Calculator::FlatRate.new(preferred_amount: 10, preferred_currency: "USD")
      )
      promotion.actions.each { |action| action.perform(order: order, promotion: promotion) }
      order.reload
      order.update_with_updater!
      order.reload

      expect(promotion.reload.code).to be_nil

      line_item = line_item_for(standard_product)
      line = payload.lines.find { |l| l["Description"].start_with?(line_item.name) }
      expect(line["Description"]).to eq("#{line_item.name} (AUTUMN SALE applied)")
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
          taxable_basis: BigDecimal("1.00"),
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
        expect { payload.to_h }.to raise_error(Spree::Kashflow::TotalMismatchError, /Unreconcilable widget/)
      end
    end

    # This used to be constructed with a real order-level promotion (a whole-order
    # `CreateAdjustment`), but fix round 1 made the mapper use `taxable_basis`
    # specifically so whole-order promotions reconcile correctly (see the
    # "order-level promotion" context below) — so that scenario no longer
    # diverges, and can no longer exercise this branch. Guard 2 is now exercised
    # with an engineered double instead: a line item that reconciles perfectly on
    # its own (proving guard 1 passes), paired with an order whose `total` is
    # simply wrong for what the lines add up to.
    context "when the assembled total diverges from order.total" do
      let(:reconciling_line_item) do
        instance_double(
          Spree::LineItem,
          name: "Reconciling widget",
          taxable_basis: BigDecimal("10.00"),
          included_tax_total: BigDecimal(0),
          quantity: 1,
          adjustments: Spree::Adjustment.none
        )
      end
      let(:order) do
        instance_double(
          Spree::Order,
          line_items: [reconciling_line_item],
          shipments: [],
          currency: "USD",
          total: BigDecimal("999.00")
        )
      end

      it "raises TotalMismatchError" do
        expect { payload.to_h }.to raise_error(Spree::Kashflow::TotalMismatchError, /order\.total/)
      end
    end

    context "when an order-level promotion applies" do
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

      it "applies the order-level discount (fixture precondition)" do
        expect(order.adjustment_total).to eq(BigDecimal("-5"))
      end

      it "syncs successfully instead of raising" do
        expect { payload.to_h }.not_to raise_error
      end

      it "produces a payload whose assembled total reconciles with order.total" do
        result = payload.to_h
        assembled = result["NetAmount"] + result["VATAmount"]
        expect(assembled).to eq(order.total)
      end
    end

    # Regression for the three-line case. `taxable_basis` allocates a whole-order
    # discount across the lines unrounded, so each of three £10 lines gets a
    # basis of 8.333333…; rounded per line that assembles to 24.99 against an
    # order.total of 25.00, and the guard raised permanently. With TWO lines the
    # residues cancel exactly, which is why the single- and two-line fixtures
    # above passed for the wrong reason. Three is the smallest count that
    # actually exercises the allocation.
    context "when an order-level promotion leaves a penny residue across three lines" do
      let(:order) do
        order = create(:order_with_line_items, store: store, currency: "USD", line_items_count: 0,
          ship_address: create(:address), shipment_cost: 0)
        3.times do
          create(:line_item, order: order, variant: create(:product, price: 10, tax_category: nil).master,
            price: 10, quantity: 1, currency: "USD")
        end
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

      it "has three lines, a £5 order-level discount and a £25 total (fixture precondition)" do
        expect(order.line_items.length).to eq(3)
        expect(order.adjustment_total).to eq(BigDecimal("-5"))
        expect(order.total).to eq(BigDecimal(25))
      end

      it "does not raise TotalMismatchError" do
        expect { payload.to_h }.not_to raise_error
      end

      it "pushes the residual penny onto one line rather than losing it" do
        lines = payload.to_h["Lines"]
        product_rates = lines
          .reject { |line| line["Description"] == described_class::SHIPPING_DESCRIPTION }
          .map { |line| line["Rate"] }

        expect(lines.sum { |line| line["Rate"] }).to eq(BigDecimal(25))
        expect(product_rates.sort).to eq([BigDecimal("8.33"), BigDecimal("8.33"), BigDecimal("8.34")])
      end

      it "produces a payload whose assembled total reconciles with order.total" do
        result = payload.to_h
        expect(result["NetAmount"] + result["VATAmount"]).to eq(order.total)
      end
    end
  end
end
