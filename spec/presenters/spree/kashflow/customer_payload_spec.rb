# frozen_string_literal: true

require "spec_helper"

RSpec.describe Spree::Kashflow::CustomerPayload do
  subject(:payload) { described_class.new(order) }

  let(:store_country) { build_stubbed(:country, iso: "GB", iso3: "GBR", name: "United Kingdom", iso_name: "UNITED KINGDOM") }
  let(:store) { build_stubbed(:store, default_country: store_country) }
  let(:billing_country) { store_country }
  let(:bill_address) do
    build_stubbed(
      :address,
      firstname: "Ada",
      lastname: "Lovelace",
      company: "Analytical Engines Ltd",
      address1: "12 Mercer Street",
      address2: "Floor 3",
      city: "London",
      state_name: "Greater London",
      zipcode: "WC2H 9QJ",
      country: billing_country
    )
  end
  let(:order) do
    build_stubbed(:order, email: "ada@example.com", bill_address: bill_address, store: store)
  end

  describe "#to_h" do
    # Savon serialises a Hash body in insertion order and a .NET ASMX endpoint
    # enforcing <s:sequence> drops or mis-binds an out-of-order element rather
    # than raising, so this ordering is load-bearing. Relative order taken
    # directly from the vendored WSDL's `Customer` complex type: … Address4,
    # CountryName, CountryCode, Postcode, Website, EC, OutsideEC, …
    # ContactFirstName, ContactLastName, … VATNumber.
    it "emits keys in WSDL sequence order" do
      expect(payload.to_h.keys).to eq(%w[
        Code Name Email Address1 Address2 Address3 Address4 CountryCode Postcode
        EC OutsideEC ContactFirstName ContactLastName
      ])
    end

    context "with a VAT number in order metadata" do
      let(:order) do
        build_stubbed(:order, email: "ada@example.com", bill_address: bill_address, store: store,
          metadata: {"vat_number" => "GB123456789"})
      end

      it "appends VATNumber last, where the sequence declares it" do
        expect(payload.to_h.keys.last).to eq("VATNumber")
      end
    end

    context "when the order has no billing address" do
      let(:order) { build_stubbed(:order, email: "ada@example.com", bill_address: nil, store: store) }

      it "sends the address fields as absent instead of raising NoMethodError" do
        expect(payload.to_h).to include(
          "Address1" => nil,
          "Postcode" => nil,
          "CountryCode" => nil,
          "ContactFirstName" => nil
        )
      end

      it "falls back to the order email for Name" do
        expect(payload.to_h["Name"]).to eq("ada@example.com")
      end
    end

    it "maps the billing address into the KashFlow address fields" do
      expect(payload.to_h).to include(
        "Address1" => "12 Mercer Street",
        "Address2" => "Floor 3",
        "Address3" => "London",
        "Address4" => "Greater London",
        "Postcode" => "WC2H 9QJ",
        "CountryCode" => "GB"
      )
    end

    it "uses the order email as the Email field" do
      expect(payload.to_h["Email"]).to eq("ada@example.com")
    end

    it "uses the order email as the Code field" do
      expect(payload.to_h["Code"]).to eq("ada@example.com")
    end

    it "splits the billing name into ContactFirstName and ContactLastName" do
      expect(payload.to_h).to include("ContactFirstName" => "Ada", "ContactLastName" => "Lovelace")
    end

    context "when the billing address has a company" do
      it "uses the company as the Name field" do
        expect(payload.to_h["Name"]).to eq("Analytical Engines Ltd")
      end

      it "still carries the person on ContactFirstName/ContactLastName" do
        expect(payload.to_h).to include("ContactFirstName" => "Ada", "ContactLastName" => "Lovelace")
      end
    end

    context "when the billing address has no company" do
      let(:bill_address) do
        build_stubbed(
          :address,
          firstname: "Ada",
          lastname: "Lovelace",
          company: nil,
          address1: "12 Mercer Street",
          address2: "Floor 3",
          city: "London",
          state_name: "Greater London",
          zipcode: "WC2H 9QJ",
          country: billing_country
        )
      end

      it "falls back to the billing full name as the Name field" do
        expect(payload.to_h["Name"]).to eq("Ada Lovelace")
      end
    end

    context "when the billing country matches the store's own country" do
      it "sets EC and OutsideEC to 0" do
        expect(payload.to_h).to include("EC" => 0, "OutsideEC" => 0)
      end
    end

    context "when the billing country is in the EU and differs from the store's country" do
      let(:billing_country) { build_stubbed(:country, iso: "FR", iso3: "FRA", name: "France", iso_name: "FRANCE") }

      it "sets EC to 1" do
        expect(payload.to_h["EC"]).to eq(1)
      end

      it "sets OutsideEC to 0" do
        expect(payload.to_h["OutsideEC"]).to eq(0)
      end
    end

    context "when the billing country is outside both the UK and the EU" do
      let(:billing_country) { build_stubbed(:country, iso: "US", iso3: "USA", name: "United States of America", iso_name: "UNITED STATES") }

      it "sets OutsideEC to 1" do
        expect(payload.to_h["OutsideEC"]).to eq(1)
      end

      it "sets EC to 0" do
        expect(payload.to_h["EC"]).to eq(0)
      end
    end

    context "when the order has a VAT number" do
      let(:order) do
        build_stubbed(
          :order,
          email: "ada@example.com",
          bill_address: bill_address,
          store: store,
          metadata: {"vat_number" => "GB123456789"}
        )
      end

      it "includes the VATNumber field" do
        expect(payload.to_h["VATNumber"]).to eq("GB123456789")
      end
    end

    context "when the order has no VAT number" do
      it "omits the VATNumber key" do
        expect(payload.to_h).not_to have_key("VATNumber")
      end
    end
  end
end
