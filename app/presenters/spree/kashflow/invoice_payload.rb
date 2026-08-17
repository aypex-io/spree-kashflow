# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Maps a Spree order onto the shape KashFlow's `Invoice` complex type expects.
    #
    # TKF prices are VAT-inclusive; KashFlow wants net (VAT-exclusive) per-unit rates.
    # Because a per-unit `Rate` is rounded to 4 decimal places, `Rate * Quantity` is
    # not guaranteed to reconcile back to the line's net total, or the assembled
    # invoice back to the order's total. `#to_h` asserts both reconciliations before
    # returning and raises {Spree::Kashflow::TotalMismatchError} rather than post a
    # silently-wrong invoice. Pure object: reads the order and its associations,
    # performs no network calls, and writes nothing back to Spree.
    #
    class InvoicePayload
      # @return [String] the description used for the shipping line
      SHIPPING_DESCRIPTION = "Shipping"

      ##
      # @param order [Spree::Order] a completed order to post as an invoice
      # @param integration [Spree::Integrations::Kashflow] the integration whose
      #   nominal codes decide which ledger accounts the lines post to
      #
      def initialize(order, integration:)
        @order = order
        @integration = integration
      end

      ##
      # @return [Array<Hash{String => Object}>] the KashFlow `InvoiceLine` structures:
      #   one per Spree line item, plus one for shipping
      #
      def lines
        line_entries.map { |entry| entry[:line] }
      end

      ##
      # Assembles the KashFlow `Invoice` structure, guarding the arithmetic before
      # returning it.
      #
      # @return [Hash{String => Object}] a KashFlow `Invoice` structure
      # @raise [Spree::Kashflow::TotalMismatchError] when a line's `Rate * Quantity`
      #   fails to reconcile against its net total, or the assembled invoice fails
      #   to reconcile against the order's total
      #
      def to_h
        entries = line_entries
        assert_totals_reconcile!(entries)

        {
          "CurrencyCode" => order.currency,
          "Lines" => entries.map { |entry| entry[:line] },
          "NetAmount" => entries.sum { |entry| entry[:net_total] }.round(2),
          "VATAmount" => entries.sum { |entry| entry[:line]["VatAmount"] }
        }
      end

      private

      # @return [Spree::Order]
      attr_reader :order

      # @return [Spree::Integrations::Kashflow]
      attr_reader :integration

      ##
      # @return [Array<Hash{Symbol => Object}>] one entry per line item and one for
      #   shipping, each carrying both the public `:line` hash and the unrounded
      #   `:net_total` the guard reconciles it against
      #
      def line_entries
        order.line_items.map { |line_item| line_item_entry(line_item) } +
          order.shipments.map { |shipment| shipment_entry(shipment) }
      end

      ##
      # @param line_item [Spree::LineItem]
      # @return [Hash{Symbol => Object}]
      #
      def line_item_entry(line_item)
        build_entry(
          gross: line_item.amount + line_item.promo_total,
          included_tax_total: line_item.included_tax_total,
          quantity: BigDecimal(line_item.quantity),
          description: line_item_description(line_item),
          charge_type: integration.preferred_sales_nominal_code
        )
      end

      ##
      # @param shipment [Spree::Shipment]
      # @return [Hash{Symbol => Object}]
      #
      def shipment_entry(shipment)
        build_entry(
          gross: shipment.cost + shipment.promo_total,
          included_tax_total: shipment.included_tax_total,
          quantity: BigDecimal(1),
          description: SHIPPING_DESCRIPTION,
          charge_type: integration.preferred_shipping_nominal_code
        )
      end

      ##
      # @param gross [BigDecimal] the discounted, VAT-inclusive amount
      # @param included_tax_total [BigDecimal] the VAT baked into `gross`
      # @param quantity [BigDecimal]
      # @param description [String]
      # @param charge_type [Integer] the KashFlow nominal code for this line
      # @return [Hash{Symbol => Object}]
      #
      def build_entry(gross:, included_tax_total:, quantity:, description:, charge_type:)
        net_total = gross - included_tax_total
        rate = (net_total / quantity).round(4)

        {
          net_total: net_total,
          line: {
            "Quantity" => quantity,
            "Description" => description,
            "Rate" => rate,
            "ChargeType" => charge_type,
            "VatRate" => vat_rate(included_tax_total, net_total),
            "VatAmount" => included_tax_total
          }
        }
      end

      ##
      # @param included_tax_total [BigDecimal]
      # @param net_total [BigDecimal]
      # @return [BigDecimal] the VAT rate as a percentage, 0 when the line is
      #   entirely discounted away
      #
      def vat_rate(included_tax_total, net_total)
        return BigDecimal(0) if net_total.zero?
        (included_tax_total / net_total * 100).round(2)
      end

      ##
      # @param line_item [Spree::LineItem]
      # @return [String] the product name, suffixed with the applied promotion
      #   codes when any eligible promotion adjustment applies to this line
      #
      def line_item_description(line_item)
        codes = promotion_codes(line_item)
        return line_item.name if codes.empty?
        "#{line_item.name} (#{codes.join(", ")} applied)"
      end

      ##
      # @param line_item [Spree::LineItem]
      # @return [Array<String>] the codes of eligible promotions applied to this line
      #
      def promotion_codes(line_item)
        line_item.adjustments.select(&:promotion?).select(&:eligible?)
          .map { |adjustment| adjustment.source.promotion.code }
          .compact.uniq
      end

      ##
      # The correctness guard. Raises rather than returns a payload whose figures
      # do not reconcile — a failed sync is a queryable flag, a wrong invoice is a
      # discrepancy someone finds at year end.
      #
      # @param entries [Array<Hash{Symbol => Object}>]
      # @return [void]
      # @raise [Spree::Kashflow::TotalMismatchError] when any line's `Rate * Quantity`
      #   fails to reconcile against its own net total, or the sum across all lines
      #   fails to reconcile against `order.total`
      #
      def assert_totals_reconcile!(entries)
        entries.each do |entry|
          reconciled = (entry[:line]["Rate"] * entry[:line]["Quantity"]).round(2)
          expected = entry[:net_total].round(2)
          next if reconciled == expected

          raise TotalMismatchError,
            "line #{entry[:line]["Description"].inspect}: Rate * Quantity = #{reconciled}, " \
            "net_total = #{expected}"
        end

        assembled = entries.sum { |entry| (entry[:line]["Rate"] * entry[:line]["Quantity"]).round(2) + entry[:line]["VatAmount"] }
        return if assembled == order.total

        raise TotalMismatchError,
          "assembled invoice total = #{assembled}, order.total = #{order.total}"
      end
    end
  end
end
