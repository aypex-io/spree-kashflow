# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Maps a Spree order's billing details onto the shape KashFlow's `Customer`
    # complex type expects. Pure object: reads the order and its associations, performs
    # no network calls, and writes nothing back to Spree.
    #
    class CustomerPayload
      # @return [Array<String>] ISO 3166-1 alpha-2 codes of EU member states, used to
      #   derive the `EC` VAT-treatment flag. The United Kingdom is deliberately absent:
      #   post-Brexit it is neither EU nor "outside" for KashFlow's purposes.
      EU_COUNTRY_CODES = %w[
        AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE
      ].freeze

      # @return [String] the ISO 3166-1 alpha-2 code KashFlow treats as the United Kingdom
      UNITED_KINGDOM_CODE = "GB"

      ##
      # @param order [Spree::Order] a completed order with a billing address
      #
      def initialize(order)
        @order = order
      end

      ##
      # @return [Hash{String => Object}] a KashFlow `Customer` structure keyed by the
      #   WSDL field names, ready to hand to KashFlow's customer-upsert operation
      #
      def to_h
        payload = {
          "Code" => order.email,
          "Name" => bill_address.full_name,
          "Email" => order.email,
          "Address1" => bill_address.address1,
          "Address2" => bill_address.address2,
          "Address3" => bill_address.city,
          "Address4" => bill_address.company,
          "Postcode" => bill_address.zipcode,
          "CountryCode" => billing_country_code,
          "ContactFirstName" => bill_address.firstname,
          "ContactLastName" => bill_address.lastname,
          "EC" => ec_flag,
          "OutsideEC" => outside_ec_flag
        }
        payload["VATNumber"] = vat_number if vat_number.present?
        payload
      end

      private

      # @return [Spree::Order]
      attr_reader :order

      ##
      # @return [Spree::Address] the order's billing address
      #
      def bill_address
        order.bill_address
      end

      ##
      # @return [String, nil] the billing address's ISO 3166-1 alpha-2 country code
      #
      def billing_country_code
        bill_address.country&.iso
      end

      ##
      # @return [String, nil] the store's own ISO 3166-1 alpha-2 country code
      #
      def store_country_code
        order.store&.default_country&.iso
      end

      ##
      # @return [String, nil] the order's VAT number, read from order metadata since
      #   Spree has no dedicated column for it
      #
      def vat_number
        order.metadata&.dig("vat_number")
      end

      ##
      # @return [Integer] 1 when the billing country is in the EU and differs from the
      #   store's own country, 0 otherwise
      #
      def ec_flag
        return 0 if billing_country_code == store_country_code
        EU_COUNTRY_CODES.include?(billing_country_code) ? 1 : 0
      end

      ##
      # @return [Integer] 1 when the billing country is outside both the UK and the EU,
      #   0 otherwise (including when it matches the store's own country)
      #
      def outside_ec_flag
        return 0 if billing_country_code == store_country_code
        return 0 if EU_COUNTRY_CODES.include?(billing_country_code)
        return 0 if billing_country_code == UNITED_KINGDOM_CODE
        1
      end
    end
  end
end
