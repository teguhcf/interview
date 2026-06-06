module Api::V1
  # Centralized, user-facing error messages raised by PricingService. Keeping
  # them in one place keeps the wording consistent, avoids duplication, and makes
  # the copy easy to review or localize without touching the service logic.
  module PricingErrors
    UNAVAILABLE      = "Pricing service is unavailable. Please try again later.".freeze
    RATE_LIMITED     = "Pricing service is currently rate limited. Please try again later.".freeze
    INVALID_RESPONSE = "Pricing service returned an invalid response.".freeze
    RATE_NOT_FOUND   = "Rate not found for the given parameters.".freeze

    # Template for the generic upstream failure; carries the HTTP status code.
    # Use with `format(UPSTREAM_ERROR, status: code)`.
    UPSTREAM_ERROR   = "Pricing service returned an error (HTTP %<status>s)".freeze
  end
end
