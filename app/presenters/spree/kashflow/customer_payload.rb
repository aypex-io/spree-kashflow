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

      # @return [String] the order metadata key a host application must write for
      #   `VATNumber` to be included in the payload. Spree has no dedicated VAT number
      #   column, so this gem reads it out of `order.metadata` under this key.
      VAT_NUMBER_METADATA_KEY = "vat_number"

      ##
      # KashFlow rejects a customer `Code` that carries special characters:
      #
      #   NO: The customer code specified is invalid, please re-enter without
      #       any special characters.
      #
      # v0.1.0 sent `order.email` here, so EVERY sync failed on the customer
      # upsert before an invoice was ever attempted — caught on the first live
      # order (tkf-prd order 12, 2026-08-18). The WSDL types `Code` as a bare
      # `s:string` with no facets, so the rule is server-side and undiscoverable
      # from the schema; these codes are therefore deliberately conservative —
      # uppercase alphanumerics only, comfortably short.
      #
      # `InsertCustomer` upserts BY `Code`, so the code identifies the CUSTOMER,
      # not the order. Anything per-order would create a fresh KashFlow customer
      # on every purchase instead of updating the existing one.

      # @return [String] format for a registered user's code, keyed on the Spree
      #   user id so it survives the customer changing their email address.
      USER_CODE_FORMAT = "SPU%d"

      # @return [String] format for a guest's code. Guests have no stable id, so
      #   the normalised email is hashed — same email in, same code out, which is
      #   what keeps the upsert an update rather than a duplicate.
      GUEST_CODE_FORMAT = "SPG%s"

      # @return [Integer] hex characters of the email digest kept in a guest code.
      #   12 hex chars is 48 bits: collision-safe at any plausible customer count
      #   while leaving the total code short.
      GUEST_CODE_DIGEST_LENGTH = 12

      # @return [Integer] the longest code this presenter will emit. KashFlow does
      #   not publish the limit in the WSDL; this is a conservative ceiling that
      #   both formats stay well inside.
      CODE_MAX_LENGTH = 20

      ##
      # @param order [Spree::Order] a completed order with a billing address
      #
      def initialize(order)
        @order = order
      end

      ##
      # Keys are emitted in the WSDL `Customer` `<s:sequence>`'s relative order —
      # `… Address4, CountryName, CountryCode, Postcode, Website, EC, OutsideEC,
      # … ContactFirstName, ContactLastName, … VATNumber`. Savon serialises a
      # Hash body in insertion order, and a .NET ASMX endpoint enforcing that
      # sequence drops or mis-binds an out-of-order element rather than raising,
      # so the order of these keys is load-bearing, not cosmetic.
      #
      # @return [Hash{String => Object}] a KashFlow `Customer` structure keyed by the
      #   WSDL field names, ready to hand to KashFlow's customer-upsert operation
      #
      def to_h
        payload = {
          "Code" => customer_code,
          "Name" => customer_name,
          "Email" => order.email,
          "Address1" => bill_address&.address1,
          "Address2" => bill_address&.address2,
          "Address3" => bill_address&.city,
          "Address4" => bill_address&.state_name_text,
          "CountryCode" => billing_country_code,
          "Postcode" => bill_address&.zipcode,
          "EC" => ec_flag,
          "OutsideEC" => outside_ec_flag,
          "ContactFirstName" => bill_address&.firstname,
          "ContactLastName" => bill_address&.lastname
        }
        payload["VATNumber"] = vat_number if vat_number.present?
        payload
      end

      private

      # @return [Spree::Order]
      attr_reader :order

      ##
      # The KashFlow customer reference. See {USER_CODE_FORMAT} for why this is
      # keyed on the customer rather than the order, and why it is alphanumeric.
      #
      # The order-number fallback is unreachable for a completed order — Spree
      # validates email presence — but it exists so a blank email cannot collapse
      # every such order onto one shared code, which would merge unrelated
      # customers into a single KashFlow record.
      #
      # @return [String] an uppercase-alphanumeric customer code
      #
      def customer_code
        return format(USER_CODE_FORMAT, order.user_id) if order.user_id.present?
        return order.number if normalized_email.blank?

        format(GUEST_CODE_FORMAT, email_digest)
      end

      ##
      # @return [String] the order email, lowercased and stripped, so that the
      #   same guest is not split across several KashFlow customers by casing or
      #   stray whitespace
      #
      def normalized_email
        order.email.to_s.strip.downcase
      end

      ##
      # @return [String] the leading {GUEST_CODE_DIGEST_LENGTH} hex characters of
      #   the normalised email's SHA-256, uppercased
      #
      def email_digest
        Digest::SHA256.hexdigest(normalized_email)[0, GUEST_CODE_DIGEST_LENGTH].upcase
      end

      ##
      # Nullable on purpose. A digital-only order can complete with no billing
      # address at all, and a `NoMethodError` here would escape the sync job's
      # `Spree::Kashflow::Error` rescue entirely — failing with no
      # `kashflow.sync_error` recorded. Every caller navigates this safely and
      # sends the address fields as absent instead.
      #
      # @return [Spree::Address, nil] the order's billing address, when it has one
      #
      def bill_address
        order.bill_address
      end

      ##
      # KashFlow separates the customer (an organisation, for business buyers) from the
      # contact person on the order. The billing company stands in for the former when
      # present; an individual buyer's name is used otherwise.
      #
      # @return [String, nil] the billing company name, the billing full name when
      #   there is no company, or the order's email when there is no billing
      #   address at all
      #
      def customer_name
        bill_address&.company.presence || bill_address&.full_name.presence || order.email
      end

      ##
      # @return [String, nil] the billing address's ISO 3166-1 alpha-2 country code
      #
      def billing_country_code
        bill_address&.country&.iso
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
        order.metadata&.dig(VAT_NUMBER_METADATA_KEY)
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
