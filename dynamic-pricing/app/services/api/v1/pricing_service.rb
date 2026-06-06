module Api::V1
  class PricingService < BaseService
    # A fetched rate is valid for 5 minutes, so we cache for the same window.
    CACHE_TTL = 5.minutes

    # When a key expires under concurrent load, let the first caller refresh it
    # while others briefly serve the stale value. This prevents a "cache
    # stampede" where every in-flight request hits the upstream at once and
    # burns through the daily API budget.
    RACE_CONDITION_TTL = 2.seconds

    # Low-level failures HTTParty/Net::HTTP raise when the upstream is slow,
    # unreachable, refuses the connection, or cannot be resolved. We translate
    # all of them into a single user-facing error rather than leaking a 500.
    NETWORK_ERRORS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      SocketError
    ].freeze

    # HTTP 429 from the upstream means we've hit the per-token rate limit; we
    # surface a distinct "rate limited" message rather than a generic error.
    RATE_LIMITED_STATUS = 429

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      @result = read_through_cache
    rescue RateApiError => e
      errors << e.message
    end

    private

    # Read-through cache with singleflight protection.
    #
    # The fast path returns a warm hit without taking any lock, so steady-state
    # reads for a key never serialize. On a cold/expired miss, SingleFlight
    # collapses concurrent callers for this key: only the first runs the fetch
    # while the rest block, then fall through to a cache hit (double-checked
    # locking) instead of each firing its own upstream request. This guards the
    # daily API budget against a thundering herd when a key is cold -- e.g. the
    # first request, post-deploy, or after a Redis eviction -- the case
    # race_condition_ttl (which needs an existing expired value to serve as
    # stale) does not cover.
    def read_through_cache
      cached = Rails.cache.read(cache_key)
      return cached unless cached.nil?

      SingleFlight.run(cache_key) do
        Rails.cache.fetch(cache_key, expires_in: CACHE_TTL, race_condition_ttl: RACE_CONDITION_TTL) do
          log(:info, "pricing.cache_miss")
          fetch_from_api
        end
      end
    end

    # Safe to interpolate raw params: the controller allowlists period/hotel/room
    # before the service runs, so these are always one of a fixed 36 combinations.
    def cache_key
      "rate/#{@period}/#{@hotel}/#{@room}"
    end

    def fetch_from_api
      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)
      handle_response(response)
    rescue *NETWORK_ERRORS => e
      log(:error, "pricing.upstream_unreachable", error: e.class)
      raise RateApiError, PricingErrors::UNAVAILABLE
    end

    def handle_response(response)
      return extract_rate(response) if response.success?

      if response.code == RATE_LIMITED_STATUS
        log(:warn, "pricing.rate_limited")
        raise RateApiError, PricingErrors::RATE_LIMITED
      else
        log(:error, "pricing.upstream_error", status: response.code)
        raise RateApiError, format(PricingErrors::UPSTREAM_ERROR, status: response.code)
      end
    end

    def extract_rate(response)
      parsed = JSON.parse(response.body)
      entry = parsed[RateApiKeys::RATES]&.detect { |r|
        r[RateApiKeys::PERIOD] == @period &&
          r[RateApiKeys::HOTEL] == @hotel &&
          r[RateApiKeys::ROOM] == @room
      }

      if entry.nil? || !entry.key?(RateApiKeys::RATE)
        log(:error, "pricing.rate_not_found")
        raise RateApiError, PricingErrors::RATE_NOT_FOUND
      end

      rate = normalize_rate(entry[RateApiKeys::RATE])
      if rate.nil?
        log(:error, "pricing.invalid_rate", value: entry[RateApiKeys::RATE].inspect)
        raise RateApiError, PricingErrors::INVALID_RESPONSE
      end

      log(:info, "pricing.fetched", rate: rate)
      rate
    rescue JSON::ParserError => e
      log(:error, "pricing.invalid_response", error: e.class)
      raise RateApiError, PricingErrors::INVALID_RESPONSE
    end

    # The upstream returns the rate inconsistently as either an integer (44900)
    # or a numeric string ("64000"). Rates are whole-number prices across every
    # combination we observed, so we normalize to Integer to give our own
    # clients a stable response contract. Returns nil for anything non-numeric.
    def normalize_rate(raw)
      case raw
      when Integer then raw
      when Numeric then raw.to_i
      when String then Integer(raw, exception: false)
      end
    end

    # Emits a single structured (key=value) log line so cache misses, upstream
    # failures, and successful fetches are all greppable in production.
    def log(level, event, **fields)
      payload = { event: event, period: @period, hotel: @hotel, room: @room }.merge(fields)
      Rails.logger.public_send(level, payload.map { |k, v| "#{k}=#{v}" }.join(" "))
    end
  end
end
