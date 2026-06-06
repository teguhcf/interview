class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
  default_timeout 10

  def self.get_rate(period:, hotel:, room:)
    body = {
      attributes: [{ period: period, hotel: hotel, room: room }]
    }.to_json
    post("/pricing", body: body)
  end
end
