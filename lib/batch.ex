defmodule Carve.Batch do
  @moduledoc """
  Batched cache warm-up for views that define `cache_many`.

  `warm/3` resolves the cached value for a set of entities of one view in a
  single `__cache_many__/1` call, instead of one `__cache__/1` call per
  entity. Views without `cache_many` fall back to the per-entity path,
  preserving the existing `cache` behavior exactly.
  """

  @doc """
  Returns a map of entity id => cached value for every entity in `items`,
  warming the request cache along the way.

  For a view with `cache_many`, entities already present in the request
  cache are excluded from the batch call; ids missing from the returned
  map are cached as nil. Batching also works when caching is disabled
  (`cache_key` is nil): the batch still runs once and the results are
  returned directly.
  """
  def warm(module, items, cache_key) when is_list(items) do
    items =
      items
      |> Enum.reject(&(entity_id(&1) == nil))
      |> Enum.uniq_by(&entity_id/1)

    if batched?(module) do
      warm_batched(module, items, cache_key)
    else
      Map.new(items, fn item ->
        id = entity_id(item)

        value =
          Carve.Cache.fetch(cache_key, {module, :cache, id}, fn ->
            module.__cache__(item)
          end)

        {id, value}
      end)
    end
  end

  @doc """
  Whether the view module declares `cache_many`.
  """
  def batched?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__cache_many__, 1)
  end

  @doc false
  def entity_id(%{id: id}), do: id
  def entity_id(%{"id" => id}), do: id
  def entity_id(_), do: nil

  defp warm_batched(module, items, cache_key) do
    {hits, misses} =
      Enum.reduce(items, {%{}, []}, fn item, {hits, misses} ->
        id = entity_id(item)

        case Carve.Cache.peek(cache_key, {module, :cache, id}) do
          {:ok, value} -> {Map.put(hits, id, value), misses}
          :error -> {hits, [item | misses]}
        end
      end)

    case Enum.reverse(misses) do
      [] ->
        hits

      misses ->
        batch = module.__cache_many__(misses)

        Enum.reduce(misses, hits, fn item, acc ->
          id = entity_id(item)
          value = Map.get(batch, id)
          Carve.Cache.put(cache_key, {module, :cache, id}, value)
          Map.put(acc, id, value)
        end)
    end
  end
end
