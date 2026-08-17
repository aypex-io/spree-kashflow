# frozen_string_literal: true

module Spree
  module Integrations
    ##
    # Per-store KashFlow credentials and posting configuration.
    #
    # The four numeric preferences decide which ledger accounts money lands in and deliberately have no
    # defaults: a wrong nominal code silently posts revenue to the wrong place, so the integration cannot
    # be saved until an operator chooses them.
    #
    class Kashflow < Spree::Integration
      preference :username, :string
      preference :password, :password
      preference :sales_nominal_code, :integer
      preference :shipping_nominal_code, :integer
      preference :bank_account_id, :integer
      preference :payment_method_id, :integer

      validates :preferred_username, :preferred_password, presence: true
      validates :preferred_sales_nominal_code,
        :preferred_shipping_nominal_code,
        :preferred_bank_account_id,
        :preferred_payment_method_id,
        presence: true,
        numericality: {only_integer: true, greater_than: 0}

      ##
      # @return [String] the admin group this integration is listed under
      #
      def self.integration_group
        "Accounting"
      end

      ##
      # @return [String] path to the bundled logo, relative to the asset root
      #
      def self.icon_path
        "integration_icons/kashflow-logo.png"
      end

      ##
      # @return [String] the name shown in the admin
      #
      def self.integration_name
        Spree.t("admin.integrations.kashflow.brand_name")
      end

      ##
      # Verifies the stored credentials against the KashFlow API.
      #
      # @return [TrueClass, FalseClass] true when KashFlow accepts the credentials
      #
      def can_connect?
        client.verify_credentials
      rescue Spree::Kashflow::Error => e
        self.connection_error_message = e.message
        false
      end

      ##
      # @return [Spree::Kashflow::Client] a client bound to this integration's credentials
      #
      def client
        Spree::Kashflow::Client.new(username: preferred_username, password: preferred_password)
      end

      ##
      # @return [Array<Array(String, Integer)>] nominal code `[name, id]` pairs for
      #   `options_for_select`; empty when credentials are absent or the lookup fails
      #
      def nominal_code_options
        options_from { client.nominal_codes }
      end

      ##
      # @return [Array<Array(String, Integer)>] bank account `[name, id]` pairs for
      #   `options_for_select`; empty when credentials are absent or the lookup fails
      #
      def bank_account_options
        options_from { client.bank_accounts }
      end

      private

      ##
      # Fetches rows from KashFlow and maps them to `options_for_select` pairs. Degrades to an
      # empty array whenever the dropdown can't be trusted: credentials not yet entered (the
      # client is never built in that case) or the connected account rejecting or failing the
      # request — an admin opening this form must always see it render, not a 500.
      #
      # @yieldreturn [Array<Hash>] rows as `{id:, name:}` hashes
      # @return [Array<Array(String, Integer)>]
      #
      def options_from
        return [] if preferred_username.blank? || preferred_password.blank?

        yield.map { |row| [row[:name], row[:id]] }
      rescue Spree::Kashflow::Error
        []
      end
    end
  end
end
