# lib/cache.ex - Add enabled check
defmodule Carve.Cache do
  @moduledoc """
  Request-scoped cache for Carve to prevent redundant data fetching within a single render.
  Each render operation gets its own isolated cache that expires after 100ms.

  Can be disabled via config:

      config :carve, Carve.Config,
        enable_cache: false
  """

  @ttl 100

  @doc """
  Creates a new cache context for a render operation.
  Returns a cache key that should be passed through the render pipeline.
  """
  def new_context do
    if Carve.Config.caching_enabled?() do
      cache_key = make_ref()
      Cachex.put(:carve_cache, cache_key, %{}, ttl: @ttl)
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
      case Cachex.get(:carve_cache, cache_key) do
        {:ok, nil} ->
          fun.()

        {:ok, cache_data} ->
          case Map.get(cache_data, key) do
            nil ->
              value = fun.()
              updated_cache = Map.put(cache_data, key, value)
              Cachex.put(:carve_cache, cache_key, updated_cache, ttl: @ttl)
              value

            cached_value ->
              cached_value
          end

        {:error, _} ->
          fun.()
      end
    else
      fun.()
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
