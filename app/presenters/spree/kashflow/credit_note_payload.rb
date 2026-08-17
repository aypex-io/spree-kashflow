# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Maps a Spree refund onto the shape KashFlow's `Invoice` complex type expects.
    # KashFlow has no `InsertCreditNote` operation: a credit note is an invoice with
    # negative values, posted through the same `InsertInvoice_TypeDefined` path and
    # then linked to the invoice it credits via `applyCreditNoteToInvoice` (Task 7's
    # job, not this class's — this class only carries the original invoice number
    # through `CustomerReference` so that call can be made).
    #
    # A refund equal to the order's total produces a full negative mirror of the
    # invoice's lines, built by delegating to {Spree::Kashflow::InvoicePayload#to_h}
    # so the credit note inherits that class's reconciliation guard rather than
    # bypassing it. A partial refund produces a single negative line for the
    # refunded amount: Spree carries no information tying a partial refund back to
    # specific line items or VAT rates, so no apportionment across the original
    # lines is attempted. Instead, VAT on that single line is approximated at the
    # order's blended rate (`order.included_tax_total / (order.total -
    # order.included_tax_total)`) — a deliberate simplification, not a derivation
    # from the refunded item(s), since Spree does not expose which items a partial
    # refund was for.
    #
    # Pure object: reads the refund and its associations, performs no network
    # calls, and writes nothing back to Spree.
    #
    class CreditNotePayload
      # @return [String] the order metafield key this gem reads the original
      #   KashFlow invoice number from
      INVOICE_NUMBER_METAFIELD_KEY = "kashflow.invoice_number"

      ##
      # @param refund [Spree::Refund] the refund to post as a KashFlow credit note
      # @param integration [Spree::Integrations::Kashflow] the integration whose
      #   nominal codes decide which ledger accounts a partial-refund line posts to
      #
      def initialize(refund, integration:)
        @refund = refund
        @integration = integration
      end

      ##
      # @return [Hash{String => Object}] a KashFlow `Invoice` structure with
      #   negative values, ready to hand to KashFlow's invoice-insert operation
      # @raise [Spree::Kashflow::TotalMismatchError] when the refund is full and
      #   the underlying invoice's lines fail to reconcile against the order's
      #   total (see {Spree::Kashflow::InvoicePayload#to_h})
      #
      def to_h
        full_refund? ? full_refund_to_h : partial_refund_to_h
      end

      private

      # @return [Spree::Refund]
      attr_reader :refund

      # @return [Spree::Integrations::Kashflow]
      attr_reader :integration

      # @return [Spree::Order]
      def order
        refund.order
      end

      ##
      # @return [Boolean] whether the refund amount equals the order's total
      #
      def full_refund?
        refund.amount == order.total
      end

      ##
      # A full negative mirror of {Spree::Kashflow::InvoicePayload#to_h}'s output.
      # Deliberately calls `#to_h`, not `#lines` — `#lines` bypasses that class's
      # correctness guard, and a credit note has no arithmetic of its own to
      # re-verify the guard against, so it inherits the guard by going through the
      # reconciled method rather than reimplementing reconciliation here.
      #
      # @return [Hash{String => Object}]
      #
      def full_refund_to_h
        invoice = InvoicePayload.new(order, integration: integration).to_h

        {
          "CurrencyCode" => invoice["CurrencyCode"],
          "CustomerReference" => invoice_number,
          "Lines" => invoice["Lines"].map { |line| negate_line(line) },
          "NetAmount" => -invoice["NetAmount"],
          "VATAmount" => -invoice["VATAmount"]
        }
      end

      ##
      # @param line [Hash{String => Object}] a KashFlow `InvoiceLine` structure
      # @return [Hash{String => Object}] the same line with `Rate` and `VatAmount`
      #   negated; `Quantity` is left positive since KashFlow expresses a credit
      #   through negative values, not a negative quantity
      #
      def negate_line(line)
        line.merge("Rate" => -line["Rate"], "VatAmount" => -line["VatAmount"])
      end

      ##
      # A single negative line for the refunded amount, since Spree carries no
      # information tying a partial refund to specific line items.
      #
      # @return [Hash{String => Object}]
      #
      def partial_refund_to_h
        line = partial_refund_line

        {
          "CurrencyCode" => order.currency,
          "CustomerReference" => invoice_number,
          "Lines" => [line],
          "NetAmount" => line["Rate"],
          "VATAmount" => line["VatAmount"]
        }
      end

      ##
      # @return [Hash{String => Object}] the single `InvoiceLine` for a partial
      #   refund, in WSDL `<s:sequence>` order
      #
      def partial_refund_line
        net_total = (refund.amount / (1 + blended_vat_rate)).round(2)
        vat_total = refund.amount - net_total

        {
          "Quantity" => BigDecimal(1),
          "Description" => "Refund: #{refund.reason.name}",
          "Rate" => -net_total,
          "ChargeType" => integration.preferred_sales_nominal_code,
          "VatRate" => (blended_vat_rate * 100).round(2),
          "VatAmount" => -vat_total,
          # KashFlow does not sync against the Spree catalogue, so there is no
          # KashFlow product to reference.
          "ProductID" => 0,
          "Sort" => 1,
          # No KashFlow project is associated with these invoices.
          "ProjID" => 0,
          # Assigned by KashFlow on insert; not known until then.
          "LineID" => 0
        }
      end

      ##
      # An approximation: Spree does not record which line items or VAT rates a
      # partial refund applies to, so this spreads the order's overall VAT/net
      # ratio across the refunded amount rather than deriving it from specific
      # lines.
      #
      # @return [BigDecimal] the order's blended VAT rate, expressed as a
      #   fraction of net (not a percentage)
      #
      def blended_vat_rate
        order.included_tax_total / (order.total - order.included_tax_total)
      end

      ##
      # @return [String, nil] the original KashFlow invoice number this credit
      #   note is for, read from the order's metafields
      #
      def invoice_number
        order.get_metafield(INVOICE_NUMBER_METAFIELD_KEY)&.value
      end
    end
  end
end
