# Solution: Dynamic Pricing Proxy

This document explains the design, the trade-offs considered, and how to run and
test the service. For the original problem statement see [README.md](./README.md).

## Problem in one line

The upstream pricing model is expensive and capped at ~10,000 calls/day per
token, but a fetched rate stays valid for 5 minutes. The job is to serve user
traffic from that single token without ever returning a rate older than 5
minutes, and to fail gracefully when the model is slow or erroring.

## Approach

A **read-through cache** keyed by `(period, hotel, room)` with a TTL equal to the
rate's validity window (5 minutes). The first request for a key fetches from the
model and caches the result; every subsequent request in that 5-minute window is
served from cache without touching the model.

```
GET /api/v1/pricing                 Api::V1::PricingController
  ?period&hotel&room        ──▶     ├─ validate_params  → 400 on bad/missing input
                                    └─ PricingService#run
                                         └─ Rails.cache.fetch(key, ttl: 5.min)
                                              └─ RateApiClient → POST pricing-model
```

- `app/controllers/api/v1/pricing_controller.rb` — validates input against
  allowlists; maps upstream failures to **503**, bad input to **400**.
- `app/services/api/v1/pricing_service.rb` — caching, upstream-error translation,
  response normalization, structured logging.
- `lib/rate_api_client.rb` — thin HTTParty client with a 10s timeout.
- `lib/rate_api_error.rb` — single error type for every upstream failure mode.

## Why this meets the 10,000 req/day constraint

Caching bounds upstream calls to **at most one per key per 5-minute window**.

| Quantity | Value |
|---|---|
| Distinct `(period, hotel, room)` combinations | 4 × 3 × 3 = **36** |
| 5-minute windows per day | 1440 / 5 = **288** |
| Theoretical max upstream calls/day | 36 × 288 = **10,368** |

The theoretical ceiling is only reached if every one of the 36 keys is requested
in every window. Under the stated load (~10,000 user requests/day ≈ 6 req/min)
requests cluster onto a handful of keys within each window, so realistic upstream
volume is a small fraction of the budget — comfortably served by a single token.

## Why Redis

| Option | Verdict |
|---|---|
| `MemoryStore` (per-process) | Rejected: each Puma worker keeps its own copy, so cache hit rate drops and the model is called more than necessary. Lost on restart. |
| **Redis (`redis_cache_store`)** | **Chosen.** Shared across all workers/processes, native TTL, survives restarts, trivial to scale horizontally. |
| SQLite/Postgres table | Rejected: persisting a value that is worthless after 5 minutes adds schema, migrations, and a cleanup concern for no benefit. A TTL cache is the right tool. |

Redis is configured in `config/environments/{development,production}.rb` with a
1s connect timeout and an `error_handler` that **degrades to a cache miss** (logs
and falls through to the model) rather than 500-ing if Redis is unreachable.

## Failure handling

The assignment stresses that a reliable service anticipates failure. Every
upstream failure mode is translated into a single user-facing `503` with a
descriptive message — never a leaked stack trace.

| Condition | Response |
|---|---|
| Missing / invalid params | `400` with which field is wrong |
| Model returns HTTP 429 | `503` "currently rate limited" |
| Model returns other non-2xx | `503` "returned an error (HTTP n)" |
| Model unreachable (DNS, connection refused, reset) | `503` "service is unavailable" |
| Model times out (>10s) | `503` "service is unavailable" |
| Malformed / non-JSON body | `503` "returned an invalid response" |
| `rates` array missing the requested entry | `503` "Rate not found" |
| Failed fetches | **never cached** — the block raises before returning |

> Before the fix, an unreachable model raised an unrescued `SocketError` and the
> client received a raw `500` with a full backtrace. Connection-level errors are
> now caught (`PricingService::NETWORK_ERRORS`).

## Upstream quirks discovered while probing the model

Probing the model directly surfaced two behaviours worth handling defensively:

1. **Inconsistent rate type.** The same endpoint returns the rate as an integer
   (`44900`) most of the time but intermittently as a numeric string (`"64000"`).
   The service normalizes the rate to an **Integer** so our own clients get a
   stable contract regardless of upstream inconsistency. A non-numeric rate is
   treated as an invalid response (`503`).
2. **Intermittent 500s and empty `rates`.** The model occasionally errors or
   returns no matching entry even for valid input. These are handled by the
   error/`Rate not found` branches above.

## Cache stampede

When a key expires under concurrent load, every in-flight request would miss at
once and hit the model simultaneously, wasting the daily budget. `Rails.cache.fetch`
is configured with `race_condition_ttl: 5.seconds` so the first caller refreshes
the key while others briefly serve the slightly-stale value.

## Observability

The service emits one structured (`key=value`) log line per meaningful event —
`pricing.cache_miss`, `pricing.fetched`, `pricing.rate_limited`,
`pricing.upstream_unreachable`, `pricing.upstream_error`, `pricing.invalid_response`
— so cache misses (the only events that consume the API budget) and every failure
mode are greppable in production.

## Trade-offs and things intentionally left out

- **No request coalescing / distributed lock.** `race_condition_ttl` covers the
  common case; a full single-flight lock adds complexity not justified at 36 keys
  and 6 req/min.
- **No serve-stale-on-error.** We could return an expired rate when the model is
  down, but that risks serving a rate older than the 5-minute contract, so we
  return `503` instead. This is a deliberate correctness-over-availability choice.
- **No background pre-warming.** With only 36 keys it would work, but on-demand
  caching is simpler and the cold-miss cost is a single request.
- **Structured logging, not full JSON logs.** `key=value` lines are greppable
  without pulling in `lograge`; swapping the logger formatter is a small follow-up.

## Build, run, and test

```bash
# Build & start the stack (app + pricing-model + redis)
docker compose up -d --build

# Smoke test
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'

# Full test suite
docker compose exec interview-dev ./bin/rails test

# A single test by name
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb -n "/caches rate/"
```

The test suite stubs `RateApiClient` (no network) and swaps a `MemoryStore` in
for cache-behaviour tests, asserting hit/miss/expiry by counting upstream calls
and covering every failure branch above.

> **Local port note:** `docker-compose.yml` maps the pricing model to host `8081`
> (not `8080`) and does not publish Redis, to avoid collisions with other local
> containers. Inter-container traffic uses the Docker network unchanged.

## Use of AI assistance

The overall design — the read-through cache keyed by `(period, hotel, room)`, the
5-minute TTL matched to rate validity, choosing Redis over a per-process store,
and the decision to fail with a descriptive `503` rather than serve a stale rate
— comes from my own engineering experience. Ruby is not my primary language, so I
used a coding assistant (Claude Code) to translate those decisions into idiomatic
Rails, to write up the caching layer, failure handling, and test suite, and to
probe the pricing model for its undocumented behaviours (the string/integer rate
inconsistency and intermittent errors). I have reviewed every line and can explain
the implementation and the trade-offs behind it.
