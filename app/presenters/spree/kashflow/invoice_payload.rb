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
      # @note Unreconciled. Only {#to_h} runs the correctness guard; a caller that
      #   needs the guarantee that these lines actually add up to the order's total
      #   (Task 6's credit notes, for instance) must go through {#to_h}, not call
      #   this directly.
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
      # Assigns each entry's `Sort` as a 1-based line index (line items first, then
      # shipping). 1-based, not 0-based: `Sort` is an ordering column and 0 is also
      # the natural "unset" sentinel in the same .NET model, so a first line of 0
      # would be ambiguous between "first" and "not sorted". Of every field this
      # class fills with a placeholder, `Sort` is the one with observable
      # behaviour — it controls line ordering on the rendered KashFlow invoice —
      # and should be confirmed against a real sandbox call before relying on it.
      #
      # @return [Array<Hash{Symbol => Object}>] one entry per line item and one for
      #   shipping, each carrying both the public `:line` hash and the unrounded
      #   `:net_total` the guard reconciles it against
      #
      def line_entries
        entries = order.line_items.map { |line_item| line_item_entry(line_item) } +
          order.shipments.map { |shipment| shipment_entry(shipment) }
        entries.each_with_index { |entry, index| entry[:line]["Sort"] = index + 1 }
        entries
      end

      ##
      # @param line_item [Spree::LineItem]
      # @return [Hash{Symbol => Object}]
      #
      def line_item_entry(line_item)
        build_entry(
          gross: line_item.taxable_basis,
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
          gross: shipment.taxable_basis,
          included_tax_total: shipment.included_tax_total,
          quantity: BigDecimal(1),
          description: SHIPPING_DESCRIPTION,
          charge_type: integration.preferred_shipping_nominal_code
        )
      end

      ##
      # @param gross [BigDecimal] the taxable basis: the discounted, VAT-inclusive
      #   amount Spree itself taxes (`taxable_basis`), which already accounts for
      #   both line-level and whole-order promotion allocations
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
            "VatAmount" => included_tax_total,
            # KashFlow does not sync against the Spree catalogue, so there is no
            # KashFlow product to reference.
            "ProductID" => 0,
            # No KashFlow project is associated with these invoices.
            "ProjID" => 0,
            # Assigned by KashFlow on insert; not known until then.
            "LineID" => 0
            # "Sort" is filled in by #line_entries once every entry's position is
            # known.
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
      # @note Known limitation: this guard only accounts for VAT baked into the
      #   price (`included_tax_total`) and the whole-order allocation captured by
      #   `taxable_basis`. An order with exclusive tax (`additional_tax_total`,
      #   added on top of the price rather than included in it) is not reconciled
      #   by this arithmetic and will make the guard raise — refused rather than
      #   mis-booked, which is the safe direction, but exclusive-tax orders are not
      #   otherwise handled by this mapper.
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
