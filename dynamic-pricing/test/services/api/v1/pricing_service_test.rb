require "test_helper"

# Unit tests for the service's business logic -- caching, rate normalization,
# upstream-error translation, and singleflight -- asserted directly against the
# service contract (result / valid? / errors), with no HTTP layer involved.
# The controller test covers the HTTP concerns (validation, status mapping).
class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  VALID_PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze

  def success_response(rate: 15000)
    body = {
      "rates" => [
        { "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => rate }
      ]
    }.to_json
    OpenStruct.new(success?: true, body: body, code: 200)
  end

  def error_response(code: 500)
    OpenStruct.new(success?: false, body: '{"error":"Internal Server Error"}', code: code)
  end

  def run_service(params = VALID_PARAMS)
    service = Api::V1::PricingService.new(**params)
    service.run
    service
  end

  # --- Result / normalization ---

  test "returns the rate as an integer on success" do
    RateApiClient.stub(:get_rate, success_response(rate: 15000)) do
      service = run_service

      assert service.valid?
      assert_equal 15000, service.result
    end
  end

  test "normalizes a string rate from the upstream into an integer" do
    RateApiClient.stub(:get_rate, success_response(rate: "21200")) do
      service = run_service

      assert service.valid?
      assert_equal 21200, service.result
    end
  end

  test "is invalid when the rate is non-numeric" do
    RateApiClient.stub(:get_rate, success_response(rate: "N/A")) do
      service = run_service

      assert_not service.valid?
      assert_includes service.errors.join, "invalid response"
    end
  end

  test "is invalid when the rate is absent from the response" do
    empty = OpenStruct.new(success?: true, body: { "rates" => [] }.to_json, code: 200)

    RateApiClient.stub(:get_rate, empty) do
      service = run_service

      assert_not service.valid?
      assert_includes service.errors.join, "Rate not found"
    end
  end

  # --- Upstream-error translation ---

  test "translates a 429 into a rate-limited error" do
    RateApiClient.stub(:get_rate, error_response(code: 429)) do
      service = run_service

      assert_not service.valid?
      assert_includes service.errors.join, "rate limited"
    end
  end

  test "translates a generic upstream error" do
    RateApiClient.stub(:get_rate, error_response(code: 500)) do
      service = run_service

      assert_not service.valid?
      assert_includes service.errors.join, "returned an error"
    end
  end

  test "translates a timeout into an unavailable error" do
    RateApiClient.stub(:get_rate, ->(*) { raise Net::ReadTimeout }) do
      service = run_service

      assert_not service.valid?
      assert_includes service.errors.join, "unavailable"
    end
  end

  test "translates an unreachable host into an unavailable error" do
    RateApiClient.stub(:get_rate, ->(*) { raise SocketError, "getaddrinfo failed" }) do
      service = run_service

      assert_not service.valid?
      assert_includes service.errors.join, "unavailable"
    end
  end

  # --- Caching ---

  test "caches the rate and does not call the API again within the TTL" do
    with_memory_cache do
      call_count = 0
      stubbed = ->(**) {
        call_count += 1
        success_response
      }

      RateApiClient.stub(:get_rate, stubbed) do
        run_service
        run_service
      end

      assert_equal 1, call_count, "Second call within the TTL must be served from cache"
    end
  end

  test "refetches after the cache entry expires" do
    with_memory_cache do
      call_count = 0
      stubbed = ->(**) {
        call_count += 1
        success_response
      }

      RateApiClient.stub(:get_rate, stubbed) do
        run_service
        travel(6.minutes) { run_service }
      end

      assert_equal 2, call_count, "Expired cache must trigger a fresh API call"
    end
  end

  test "does not cache failed responses" do
    with_memory_cache do
      call_count = 0
      stubbed = ->(**) {
        call_count += 1
        error_response
      }

      RateApiClient.stub(:get_rate, stubbed) do
        run_service
        run_service
      end

      assert_equal 2, call_count, "Failed responses must not be cached"
    end
  end

  # --- Singleflight (cold-start stampede) ---

  test "collapses concurrent cold-cache requests into a single upstream call" do
    # A burst of simultaneous requests for the same key on a cold cache must
    # trigger only ONE upstream call -- the first fetches and fills the cache,
    # the rest wait and share the result rather than stampeding the API. Without
    # the singleflight lock this records ~50 calls; with it, exactly 1.
    with_memory_cache do
      call_count = 0
      count_guard = Mutex.new
      stubbed = ->(**) {
        count_guard.synchronize { call_count += 1 }
        sleep 0.05 # hold the "upstream" so all threads pile onto the lock
        success_response
      }

      RateApiClient.stub(:get_rate, stubbed) do
        threads = 50.times.map { Thread.new { run_service } }
        threads.each(&:join)
      end

      assert_equal 1, call_count,
        "Concurrent cold-cache requests for the same key must trigger only one upstream call"
    end
  end

  private

  def with_memory_cache
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original_cache
  end
end
