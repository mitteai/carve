defmodule Carve.RenderCostTest do
  # Pins down two render-cost defects observed in production: a 50-asset
  # page render spent ~1.4s inside Carve with only ~90ms of DB work.
  #
  # Not async: the Hashids test uses cprof (global), and the cache tests
  # mutate the :carve application env.
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:carve, Carve.Config, [])

    on_exit(fn ->
      Application.put_env(:carve, Carve.Config, original)
      Carve.HashIds.configure([])
    end)

    Application.put_env(:carve, Carve.Config, Keyword.put(original, :enable_cache, true))
    :ok
  end

  describe "request cache" do
    test "cached values survive for the whole render, regardless of TTL" do
      # The cache is request-scoped: created at the start of a render and
      # cleared at the end. A render that outlives the configured TTL must
      # not lose its cache mid-flight and start re-fetching entities.
      existing = Application.get_env(:carve, Carve.Config, [])
      Application.put_env(:carve, Carve.Config, Keyword.put(existing, :cache_ttl, 50))

      cache_key = Carve.Cache.new_context()
      counter = :counters.new(1, [])

      fetch = fn ->
        Carve.Cache.fetch(cache_key, {:user, :get, 1}, fn ->
          :counters.add(counter, 1, 1)
          %{id: 1}
        end)
      end

      fetch.()
      Process.sleep(120)
      fetch.()

      assert :counters.get(counter, 1) == 1,
             "cache lost its entries mid-render: the fetch function ran twice"
    end

    test "cache operations stay cheap as the cache grows" do
      # Every fetch used to pull the entire cache map out of the backing
      # store and every put wrote the entire map back — O(n²) copying as
      # entries accumulate during a render. 10k distinct fetches on one
      # context must complete in well under a second; the quadratic
      # implementation takes several.
      cache_key = Carve.Cache.new_context()

      {us, _} =
        :timer.tc(fn ->
          for i <- 1..10_000 do
            Carve.Cache.fetch(cache_key, {:entity, :get, i}, fn -> {:value, i} end)
          end
        end)

      assert us < 1_000_000,
             "10k cache fetches took #{div(us, 1000)}ms; expected well under 1000ms"
    end
  end

  describe "hash ids" do
    test "encode reuses the built Hashids context instead of rebuilding it per call" do
      # Hashids.new validates and shuffles the whole alphabet — far too
      # expensive to run on every encode. After configure/1, encoding must
      # reuse the built context.
      Carve.HashIds.configure(salt: "render-cost-test", min_length: 4)

      # Warm any lazy initialization before counting
      Carve.HashIds.encode(:user, 1)

      :cprof.start(Hashids)
      for i <- 1..100, do: Carve.HashIds.encode(:user, i)
      :cprof.pause()

      {Hashids, _total, funcs} = :cprof.analyse(Hashids)
      :cprof.stop()

      new_calls =
        Enum.find_value(funcs, 0, fn
          {{Hashids, :new, 1}, count} -> count
          _ -> nil
        end)

      assert new_calls == 0,
             "Hashids.new/1 ran #{new_calls} times across 100 encodes; the context must be built once"
    end
  end
end
