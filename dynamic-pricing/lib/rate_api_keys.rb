# Field names in the rate-api's JSON contract. Defined once so the wire-format
# keys live in a single place and a typo can't silently break response matching.
module RateApiKeys
  RATES  = "rates".freeze  # top-level array of rate objects in the response
  RATE   = "rate".freeze   # the price field on each rate object
  PERIOD = "period".freeze
  HOTEL  = "hotel".freeze
  ROOM   = "room".freeze
end
