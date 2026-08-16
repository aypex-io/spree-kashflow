# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Base class for every error this gem raises.
    #
    class Error < StandardError; end

    ##
    # Raised when KashFlow rejects the configured credentials. Not retryable.
    #
    class AuthenticationError < Error; end

    ##
    # Raised when KashFlow accepts the request but refuses the operation.
    #
    class ApiError < Error; end

    ##
    # Raised when the KashFlow service could not be reached. Retryable.
    #
    class TransportError < Error; end
  end
end
