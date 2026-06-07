# Singleflight / request coalescing: for a given key, only one block runs at a
# time within this process. Concurrent callers for the same key block until the
# first finishes. Paired with a read-through cache, a burst of simultaneous
# cache misses for one key produces a single upstream call -- the first caller
# fetches and populates the cache; the rest wake to a cache hit instead of
# stampeding the upstream and burning the daily API budget.
#
# Scope is per-process (an in-memory Mutex). Under multi-process Puma this
# collapses a stampede within each worker -- reducing N simultaneous cold misses
# to one upstream call per worker, not one globally. Collapsing across workers or
# hosts would require a distributed lock (e.g. Redis SET NX); that is
# intentionally out of scope here -- see SOLUTION.md for the trade-off and when
# it becomes worth adding.
class SingleFlight
  @locks = {}
  @registry_guard = Mutex.new

  class << self
    # Runs the block under a per-key lock and returns its value. Exceptions
    # propagate to the caller and release the lock, so a failed fetch is not
    # shared -- the next waiter re-checks the cache and retries if needed.
    def run(key, &block)
      lock_for(key).synchronize(&block)
    end

    private

    # One Mutex per distinct key. The key space is the controller's 36
    # allowlisted (period, hotel, room) combinations, so the registry is
    # naturally bounded and needs no eviction.
    def lock_for(key)
      @registry_guard.synchronize { @locks[key] ||= Mutex.new }
    end
  end
end
