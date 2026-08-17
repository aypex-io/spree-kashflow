# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow::SyncOrderJob do
  let(:client) do
    instance_double(
      Spree::Kashflow::Client,
      currencies: [{code: "USD", id: 1}],
      upsert_customer: 555,
      create_invoice: 98765,
      record_invoice_payment: true
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

  before do
    allow(Spree::Kashflow::Client).to receive(:new).and_return(client)
    integration
  end

  describe "#perform" do
    it "stores the KashFlow invoice number on the order" do
      described_class.perform_now(order.id)

      expect(order.reload.get_metafield(Spree::Kashflow::Metafields::ORDER_INVOICE_NUMBER).value).to eq("98765")
    end

    it "does not post a second invoice on a second run" do
      described_class.perform_now(order.id)
      described_class.perform_now(order.id)

      expect(client).to have_received(:create_invoice).once
    end

    it "emits invoice envelope keys in WSDL sequence order" do
      captured = nil
      allow(client).to receive(:create_invoice) { |payload|
        captured = payload
        98765
      }

      described_class.perform_now(order.id)

      expect(captured.keys).to eq(%w[
        InvoiceDBID InvoiceNumber InvoiceDate DueDate CustomerID Paid SuppressTotal
        ProjectID CurrencyCode ExchangeRate Lines NetAmount VATAmount AmountPaid
        UseCustomDeliveryAddress CISRCNetAmount CISRCVatAmount IsCISReverseCharge
      ])
    end

    it "sets the schema-required tail fields to arithmetically neutral defaults" do
      captured = nil
      allow(client).to receive(:create_invoice) { |payload|
        captured = payload
        98765
      }

      described_class.perform_now(order.id)

      expect(captured.values_at("UseCustomDeliveryAddress", "CISRCNetAmount", "CISRCVatAmount", "IsCISReverseCharge"))
        .to eq([false, 0, 0, false])
    end

    it "does not call the client when no integration exists for the order's store" do
      integration.destroy!

      described_class.perform_now(order.id)

      expect(client).not_to have_received(:upsert_customer)
    end

    it "does not call the client when the integration is inactive" do
      integration.update!(active: false)

      described_class.perform_now(order.id)

      expect(client).not_to have_received(:upsert_customer)
    end

    context "when the order is paid" do
      before { create(:payment, order: order, amount: order.total, state: "completed") }

      it "records a payment against the invoice" do
        described_class.perform_now(order.id)

        expect(client).to have_received(:record_invoice_payment)
      end
    end

    context "when the order is unpaid" do
      it "does not record a payment" do
        described_class.perform_now(order.id)

        expect(client).not_to have_received(:record_invoice_payment)
      end
    end

    context "when the order's currency is not enabled in KashFlow" do
      let(:client) { instance_double(Spree::Kashflow::Client, currencies: [{code: "GBP", id: 1}]) }

      it "raises an ApiError naming the currency" do
        expect { described_class.perform_now(order.id) }.to raise_error(Spree::Kashflow::ApiError, /USD/)
      end
    end

    context "when KashFlow refuses the request" do
      let(:client) { instance_double(Spree::Kashflow::Client, currencies: [{code: "USD", id: 1}]) }

      before do
        allow(client).to receive(:upsert_customer).and_raise(Spree::Kashflow::ApiError, "nominal code invalid")
      end

      it "re-raises the ApiError" do
        expect { described_class.perform_now(order.id) }.to raise_error(Spree::Kashflow::ApiError)
      end

      it "writes the failure message to kashflow.sync_error" do
        suppress(Spree::Kashflow::ApiError) { described_class.perform_now(order.id) }

        expect(order.reload.get_metafield(Spree::Kashflow::Metafields::ORDER_SYNC_ERROR).value).to eq("nominal code invalid")
      end
    end

    context "when KashFlow rejects the credentials" do
      let(:client) do
        instance_double(Spree::Kashflow::Client, currencies: [{code: "USD", id: 1}])
      end

      before do
        allow(client).to receive(:upsert_customer).and_raise(Spree::Kashflow::AuthenticationError, "bad credentials")
      end

      it "discards the job instead of raising" do
        expect { described_class.perform_now(order.id) }.not_to raise_error
      end

      it "writes the failure message to kashflow.sync_error before discarding" do
        described_class.perform_now(order.id)

        expect(order.reload.get_metafield(Spree::Kashflow::Metafields::ORDER_SYNC_ERROR).value).to eq("bad credentials")
      end
    end
  end
end
