# lib/cache.ex - Add enabled check
defmodule Carve.Cache do
  @moduledoc """
  Request-scoped cache for Carve to prevent redundant data fetching within a single render.
  Each render operation gets its own isolated cache keyed by a unique ref.
  TTL defaults to 500ms. Increase if requests involve slow queries.
  The cache is cleared at end of each render regardless of TTL.

  Configuration:

      config :carve, Carve.Config,
        enable_cache: false,
        cache_ttl: 100
  """

  @doc """
  Creates a new cache context for a render operation.
  Returns a cache key that should be passed through the render pipeline.
  """
  def new_context do
    if Carve.Config.caching_enabled?() do
      cache_key = make_ref()
      Cachex.put(:carve_cache, cache_key, %{}, ttl: Carve.Config.cache_ttl())
      cache_key
    else
      nil
    end
  end

  @doc """
  Fetches a value from cache or executes the function if not cached.
  If caching is disabled, always executes the function.
  """
  def fetch(nil, _key, fun) when is_function(fun, 0), do: fun.()

  def fetch(cache_key, key, fun) when is_function(fun, 0) do
    if Carve.Config.caching_enabled?() do
      # Map.fetch, not Map.get: a cached nil (e.g. a missing entity or a
      # cache_many id absent from the batch result) is a hit, not a miss.
      case Map.fetch(read(cache_key), key) do
        {:ok, cached_value} ->
          cached_value

        :error ->
          value = fun.()
          put(cache_key, key, value)
          value
      end
    else
      fun.()
    end
  end

  @doc """
  Looks up a cached value without computing it.
  Returns `{:ok, value}` (value may be nil) or `:error` when the key is
  absent or caching is disabled.
  """
  def peek(nil, _key), do: :error

  def peek(cache_key, key) do
    if Carve.Config.caching_enabled?() do
      Map.fetch(read(cache_key), key)
    else
      :error
    end
  end

  @doc """
  Stores a value in the request cache. No-op when caching is disabled.
  """
  def put(nil, _key, _value), do: :ok

  def put(cache_key, key, value) do
    if Carve.Config.caching_enabled?() do
      # Re-read before writing to pick up writes from nested fetch calls
      updated = Map.put(read(cache_key), key, value)
      Cachex.put(:carve_cache, cache_key, updated, ttl: Carve.Config.cache_ttl())
    end

    :ok
  end

  defp read(cache_key) do
    case Cachex.get(:carve_cache, cache_key) do
      {:ok, %{} = data} -> data
      _ -> %{}
    end
  end

  @doc """
  Gets the current cache key from the process dictionary, or creates a new one.
  Returns nil if caching is disabled.
  """
  def get_or_create_context do
    if Carve.Config.caching_enabled?() do
      case Process.get(:carve_cache_key) do
        nil ->
          cache_key = new_context()
          Process.put(:carve_cache_key, cache_key)
          cache_key

        cache_key ->
          cache_key
      end
    else
      nil
    end
  end

  @doc """
  Clears the cache context from the process dictionary.
  """
  def clear_context do
    if Carve.Config.caching_enabled?() do
      Process.delete(:carve_cache_key)
    end
  end
end
