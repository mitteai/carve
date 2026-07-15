defmodule Carve.Links do
  # Public API — returns lists (backward compatible)

  def get_links_by_id(module, id, visited \\ %{}, whitelist \\ nil, cache_key \\ nil) do
    {links, _visited} = do_get_links_by_id(module, id, visited, whitelist, cache_key)
    links
  end

  def get_links_by_data(module, data, visited \\ %{}, whitelist \\ nil, cache_key \\ nil) do
    {links, _visited} = do_get_links_by_data(module, data, visited, whitelist, cache_key)
    links
  end

  # Internal API — returns {links, visited} to accumulate visited across items

  defp do_get_links_by_id(_module, nil, visited, _whitelist, _cache_key), do: {[], visited}

  defp do_get_links_by_id(module, id, visited, whitelist, cache_key) when not is_list(id) do
    cache_key = cache_key || Carve.Cache.get_or_create_context()

    case Map.get(visited, {module, id}) do
      nil ->
        data = Carve.Cache.fetch(cache_key, {module, :get, id}, fn ->
          module.get_by_id(id)
        end)

        case data do
          nil ->
            {[], visited}

          data ->
            {links, visited} = do_get_links_by_data(module, data, visited, whitelist, cache_key)
            {prepare_result(links, whitelist), visited}
        end

      _ ->
        {[], visited}
    end
  end

  defp do_get_links_by_id(module, ids, visited, whitelist, cache_key) when is_list(ids) do
    cache_key = cache_key || Carve.Cache.get_or_create_context()

    {links, visited} =
      Enum.reduce(ids, {[], visited}, fn id, {acc, vis} ->
        {new_links, vis} = do_get_links_by_id(module, id, vis, whitelist, cache_key)
        {acc ++ new_links, vis}
      end)

    {prepare_result(links, whitelist), visited}
  end

  defp do_get_links_by_data(_module, nil, visited, _whitelist, _cache_key), do: {[], visited}

  defp do_get_links_by_data(module, data_list, visited, whitelist, cache_key)
       when is_list(data_list) do
    cache_key = cache_key || Carve.Cache.get_or_create_context()

    warm_level(module, data_list, visited, whitelist, cache_key)

    {links, visited} =
      Enum.reduce(data_list, {[], visited}, fn item, {acc, vis} ->
        {new_links, vis} = do_get_links_by_data(module, item, vis, whitelist, cache_key)
        {acc ++ new_links, vis}
      end)

    {prepare_result(links, whitelist), visited}
  end

  defp do_get_links_by_data(_module, data, visited, _whitelist, _cache_key)
       when not is_map(data),
       do: {[], visited}

  defp do_get_links_by_data(module, data, visited, whitelist, cache_key)
       when not is_list(data) do
    cache_key = cache_key || Carve.Cache.get_or_create_context()

    case fetch_id(data) do
      {:ok, id} ->
        if Map.get(visited, {module, id}) do
          {[], visited}
        else
          visited = Map.put(visited, {module, id}, true)

          cached = fetch_cached(module, data, id, cache_key)

          raw_links = fetch_links(module, data, id, cached, cache_key)

          warm_link_targets([raw_links], visited, whitelist, cache_key)

          links = filter_and_evaluate_links(raw_links, whitelist)

          {links, visited} =
            Enum.reduce(links, {[], visited}, fn {link_module, link_data_or_ids}, {acc, vis} ->
              link_data_or_ids
              |> normalize_link_ids()
              |> Enum.reduce({acc, vis}, fn link_id_or_data, {acc, vis} ->
                link = process_single_link(link_module, link_id_or_data, vis, cache_key)

                # let do_get_links_by_id/data mark visited internally
                {children, vis} =
                  if is_map(link_id_or_data) do
                    do_get_links_by_data(link_module, link_id_or_data, vis, whitelist, cache_key)
                  else
                    do_get_links_by_id(link_module, link_id_or_data, vis, whitelist, cache_key)
                  end

                {acc ++ [link | children], vis}
              end)
            end)

          {prepare_result(links, whitelist), visited}
        end

      :error ->
        {[], visited}
    end
  end

  # Fetch cached data for a module, using the Cachex cache
  defp fetch_cached(module, data, id, cache_key) do
    Carve.Cache.fetch(cache_key, {module, :cache, id}, fn ->
      module.__cache__(data)
    end)
  end

  # ── batched warm-up (cache_many) ─────────────────────────────────────

  # Memoized declare_links, so the warm-up pre-pass and the traversal
  # evaluate each entity's links function once per request.
  defp fetch_links(module, data, id, cached, cache_key) do
    Carve.Cache.fetch(cache_key, {module, :links, id}, fn ->
      module.declare_links(data, cached)
    end)
  end

  # Cross-item warm-up for a list render: batch the list's own cache, then
  # batch the cache of every linked entity set whose view defines
  # cache_many, so the per-item traversal below hits the cache throughout.
  # Skipped when caching is disabled (nil cache_key) — the traversal stays
  # correct through the per-entity batch-of-one __cache__ fallback.
  defp warm_level(_module, _data_list, _visited, _whitelist, nil), do: :ok

  defp warm_level(module, data_list, visited, whitelist, cache_key) do
    items =
      Enum.filter(data_list, fn item ->
        with true <- is_map(item),
             {:ok, id} <- fetch_id(item) do
          !Map.get(visited, {module, id})
        else
          _ -> false
        end
      end)

    cached_by_id = Carve.Batch.warm(module, items, cache_key)

    raw_links_list =
      Enum.map(items, fn item ->
        {:ok, id} = fetch_id(item)
        fetch_links(module, item, id, Map.get(cached_by_id, id), cache_key)
      end)

    warm_link_targets(raw_links_list, visited, whitelist, cache_key)
  end

  # Warm the cache of link targets, grouped by view module, one batch per
  # module that defines cache_many. Lazy (function) links are left to the
  # traversal so they are never evaluated twice.
  defp warm_link_targets(_raw_links_list, _visited, _whitelist, nil), do: :ok

  defp warm_link_targets(raw_links_list, visited, whitelist, cache_key) do
    raw_links_list
    |> Enum.flat_map(fn raw_links ->
      for {link_module, value} <- raw_links,
          not is_function(value),
          link_whitelisted?(link_module, whitelist),
          Carve.Batch.batched?(link_module),
          target <- normalize_link_ids(value),
          do: {link_module, target}
    end)
    |> Enum.group_by(fn {module, _} -> module end, fn {_, target} -> target end)
    |> Enum.each(fn {link_module, targets} ->
      entities =
        targets
        |> Enum.reject(fn target ->
          case fetch_id(target) do
            {:ok, id} -> Map.get(visited, {link_module, id}) != nil
            :error -> true
          end
        end)
        |> Enum.map(fn
          id when is_number(id) or is_binary(id) ->
            Carve.Cache.fetch(cache_key, {link_module, :get, id}, fn ->
              link_module.get_by_id(id)
            end)

          data ->
            data
        end)
        |> Enum.reject(&is_nil/1)

      Carve.Batch.warm(link_module, entities, cache_key)
    end)
  end

  defp link_whitelisted?(_module, nil), do: true
  defp link_whitelisted?(_module, []), do: false

  defp link_whitelisted?(module, whitelist) when is_list(whitelist),
    do: module.type_name() in whitelist

  defp process_single_link(module, id, visited, cache_key) when is_number(id) or is_binary(id) do
    case Map.get(visited, {module, id}) do
      nil ->
        data = Carve.Cache.fetch(cache_key, {module, :get, id}, fn ->
          module.get_by_id(id)
        end)

        case data do
          nil -> nil
          data ->
            cached = fetch_cached(module, data, id, cache_key)
            module.prepare_for_view(data, cached)
        end

      _ ->
        nil
    end
  end

  defp process_single_link(module, data, visited, cache_key) do
    case fetch_id(data) do
      {:ok, id} ->
        case Map.get(visited, {module, id}) do
          nil ->
            cached = fetch_cached(module, data, id, cache_key)
            module.prepare_for_view(data, cached)

          _ ->
            nil
        end

      :error ->
        nil
    end
  end

  defp filter_and_evaluate_links(links, nil) do
    links
    |> Enum.filter(fn {_, value} -> not is_function(value) end)
    |> Enum.into(%{})
  end

  defp filter_and_evaluate_links(_links, []), do: %{}

  defp filter_and_evaluate_links(links, whitelist) when is_list(whitelist) do
    links
    |> Enum.filter(fn {module, _} -> module.type_name() in whitelist end)
    |> Enum.map(fn {module, value} ->
      evaluated =
        case value do
          fun when is_function(fun, 0) -> fun.()
          other -> other
        end

      {module, evaluated}
    end)
    |> Enum.into(%{})
  end

  def prepare_result(result, whitelist \\ nil) do
    result
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn %{type: type, id: id} -> {type, id} end)
    |> filter_result(whitelist)
  end

  defp filter_result(_result, []), do: []
  defp filter_result(result, nil), do: result

  defp filter_result(result, whitelist) do
    Enum.filter(result, fn %{type: type} -> type in whitelist end)
  end

  defp extract_id(nil), do: nil
  defp extract_id(id) when is_number(id) or is_binary(id), do: id

  defp extract_id(data) when is_map(data) do
    case fetch_id(data) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp normalize_link_ids(link_ids) when is_list(link_ids), do: link_ids
  defp normalize_link_ids(link_id), do: [link_id]

  defp fetch_id(data) when is_map(data) do
    cond do
      Map.has_key?(data, :id) -> {:ok, data.id}
      Map.has_key?(data, "id") -> {:ok, data["id"]}
      true ->
        case Enum.at(data, 0) do
          {key, value} -> {:ok, {key, value}}
          nil -> :error
        end
    end
  end

  defp fetch_id(id) when is_integer(id) or is_binary(id), do: {:ok, id}
  defp fetch_id(_), do: :error
end
