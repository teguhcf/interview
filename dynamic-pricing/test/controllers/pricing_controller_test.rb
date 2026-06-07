require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  VALID_PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze

  def success_response(rate: 15000)
    body = {
      'rates' => [
        { 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom', 'rate' => rate }
      ]
    }.to_json
    OpenStruct.new(success?: true, body: body, code: 200)
  end

  def error_response(code: 500)
    OpenStruct.new(success?: false, body: '{"error":"Internal Server Error"}', code: code)
  end

  # --- Parameter validation ---

  test "returns 400 without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_error_includes "Missing required parameters"
  end

  test "returns 400 with empty parameters" do
    get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }

    assert_response :bad_request
    assert_error_includes "Missing required parameters"
  end

  test "returns 400 for invalid period" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(period: "Monsoon")

    assert_response :bad_request
    assert_error_includes "Invalid period"
  end

  test "returns 400 for invalid hotel" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(hotel: "InvalidHotel")

    assert_response :bad_request
    assert_error_includes "Invalid hotel"
  end

  test "returns 400 for invalid room" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(room: "InvalidRoom")

    assert_response :bad_request
    assert_error_includes "Invalid room"
  end

  # --- Successful response ---

  test "returns rate when API succeeds" do
    RateApiClient.stub(:get_rate, success_response(rate: 15000)) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :success
      assert_equal "application/json", @response.media_type
      assert_equal 15000, json_response["rate"]
    end
  end

  test "normalizes a string rate from the upstream into an integer" do
    # The pricing model intermittently returns the rate as a numeric string;
    # the service must present a consistent integer to its own clients.
    RateApiClient.stub(:get_rate, success_response(rate: "21200")) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :success
      assert_equal 21200, json_response["rate"]
    end
  end

  test "returns 503 when rate is non-numeric" do
    RateApiClient.stub(:get_rate, success_response(rate: "N/A")) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :service_unavailable
      assert_error_includes "invalid response"
    end
  end

  # --- API failure handling ---

  test "returns 503 when API returns an error" do
    RateApiClient.stub(:get_rate, error_response) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :service_unavailable
      assert_error_includes "Pricing service returned an error"
    end
  end

  test "returns 503 with rate limit message when API returns 429" do
    RateApiClient.stub(:get_rate, error_response(code: 429)) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :service_unavailable
      assert_error_includes "rate limited"
    end
  end

  test "returns 503 on API timeout" do
    RateApiClient.stub(:get_rate, ->(*) { raise Net::ReadTimeout }) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :service_unavailable
      assert_error_includes "unavailable"
    end
  end

  test "returns 503 when upstream is unreachable" do
    RateApiClient.stub(:get_rate, ->(*) { raise SocketError, "getaddrinfo failed" }) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :service_unavailable
      assert_error_includes "unavailable"
    end
  end

  test "returns 503 when upstream returns malformed JSON" do
    bad_response = OpenStruct.new(success?: true, body: "<html>502 Bad Gateway</html>", code: 200)

    RateApiClient.stub(:get_rate, bad_response) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :service_unavailable
      assert_error_includes "invalid response"
    end
  end

  test "returns 503 when rate is absent from response" do
    empty_response = OpenStruct.new(success?: true, body: { "rates" => [] }.to_json, code: 200)

    RateApiClient.stub(:get_rate, empty_response) do
      get api_v1_pricing_url, params: VALID_PARAMS

      assert_response :service_unavailable
      assert_error_includes "Rate not found"
    end
  end

  # --- Caching behavior ---

  test "caches rate and does not call API on second request" do
    with_memory_cache do
      call_count = 0
      stubbed = ->(**) {
        call_count += 1
        success_response
      }

      RateApiClient.stub(:get_rate, stubbed) do
        get api_v1_pricing_url, params: VALID_PARAMS
        assert_response :success

        get api_v1_pricing_url, params: VALID_PARAMS
        assert_response :success
      end

      assert_equal 1, call_count, "API should only be called once; second request served from cache"
    end
  end

  test "different param combinations are cached independently" do
    with_memory_cache do
      call_count = 0
      stubbed = ->(**) {
        call_count += 1
        success_response
      }

      RateApiClient.stub(:get_rate, stubbed) do
        get api_v1_pricing_url, params: VALID_PARAMS
        get api_v1_pricing_url, params: VALID_PARAMS.merge(room: "BooleanTwin")
      end

      assert_equal 2, call_count, "Different param combinations should each hit the API once"
    end
  end

  test "expired cache fetches fresh rate from API" do
    with_memory_cache do
      call_count = 0
      stubbed = ->(**) {
        call_count += 1
        success_response
      }

      RateApiClient.stub(:get_rate, stubbed) do
        get api_v1_pricing_url, params: VALID_PARAMS

        travel(6.minutes) do
          get api_v1_pricing_url, params: VALID_PARAMS
        end
      end

      assert_equal 2, call_count, "Expired cache should trigger a fresh API call"
    end
  end

  test "does not cache failed API responses" do
    with_memory_cache do
      call_count = 0
      stubbed = ->(**) {
        call_count += 1
        error_response
      }

      RateApiClient.stub(:get_rate, stubbed) do
        get api_v1_pricing_url, params: VALID_PARAMS
        get api_v1_pricing_url, params: VALID_PARAMS
      end

      assert_equal 2, call_count, "Failed responses must not be cached"
    end
  end

  private

  def json_response
    JSON.parse(@response.body)
  end

  def assert_error_includes(message)
    assert_equal "application/json", @response.media_type
    assert_includes json_response["error"], message
  end

  def with_memory_cache
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original_cache
  end
end
