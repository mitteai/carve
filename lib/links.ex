defmodule Carve.Links do
  # Update all public functions to accept cache_key as last parameter
  def get_links_by_id(module, id, visited \\ %{}, whitelist \\ nil, cache_key \\ nil)
  def get_links_by_id(_module, nil, _visited, _whitelist, _cache_key), do: []

  def get_links_by_id(module, id, visited, whitelist, cache_key) when not is_list(id) do
    cache_key = cache_key || Carve.Cache.get_or_create_context()

    case Map.get(visited, {module, id}) do
      nil ->
        # Use cache for get_by_id calls
        data = Carve.Cache.fetch(cache_key, {module, :get, id}, fn ->
          module.get_by_id(id)
        end)

        case data do
          nil -> []
          data -> get_links_by_data(module, data, visited, whitelist, cache_key) |> prepare_result(whitelist)
        end

      _ ->
        []
    end
  end

  def get_links_by_id(module, ids, visited, whitelist, cache_key) when is_list(ids) do
    cache_key = cache_key || Carve.Cache.get_or_create_context()

    Enum.flat_map(ids, &get_links_by_id(module, &1, visited, whitelist, cache_key))
    |> prepare_result(whitelist)
  end

  def get_links_by_data(module, data, visited \\ %{}, whitelist \\ nil, cache_key \\ nil)
  def get_links_by_data(_module, nil, _visited, _whitelist, _cache_key), do: []

  def get_links_by_data(module, data_list, visited, whitelist, cache_key) when is_list(data_list) do
    cache_key = cache_key || Carve.Cache.get_or_create_context()

    Enum.flat_map(data_list, &get_links_by_data(module, &1, visited, whitelist, cache_key))
    |> prepare_result(whitelist)
  end

  def get_links_by_data(_module, data, _visited, _whitelist, _cache_key) when not is_map(data), do: []

  def get_links_by_data(module, data, visited, whitelist, cache_key) when not is_list(data) do
    cache_key = cache_key || Carve.Cache.get_or_create_context()

    case fetch_id(data) do
      {:ok, id} ->
        if Map.get(visited, {module, id}) do
          []
        else
          visited = Map.put(visited, {module, id}, true)

          links =
            module.declare_links(data)
            |> filter_and_evaluate_links(whitelist)

          links =
            links
            |> Enum.flat_map(fn {link_module, link_data_or_ids} ->
              link_data_or_ids
              |> normalize_link_ids()
              |> Enum.map(fn link_id_or_data ->
                link = process_single_link(link_module, link_id_or_data, visited, cache_key)

                children =
                  if Map.get(visited, {link_module, extract_id(link_id_or_data)}) do
                    []
                  else
                    if is_map(link_id_or_data) do
                      get_links_by_data(link_module, link_id_or_data, visited, whitelist, cache_key)
                    else
                      get_links_by_id(link_module, link_id_or_data, visited, whitelist, cache_key)
                    end
                  end

                [link | children]
              end)
            end)

          prepare_result(links, whitelist)
        end

      :error ->
        []
    end
  end

  # Update process_single_link to use cache
  defp process_single_link(module, id, visited, cache_key) when is_number(id) or is_binary(id) do
    case Map.get(visited, {module, id}) do
      nil ->
        data = Carve.Cache.fetch(cache_key, {module, :get, id}, fn ->
          module.get_by_id(id)
        end)

        case data do
          nil -> nil
          data -> module.prepare_for_view(data)
        end

      _ ->
        nil
    end
  end

  defp process_single_link(module, data, visited, _cache_key) do
    case fetch_id(data) do
      {:ok, id} ->
        case Map.get(visited, {module, id}) do
          nil -> module.prepare_for_view(data)
          _ -> nil
        end

      :error ->
        nil
    end
  end

  # Keep all other private functions unchanged
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

  defp filter_result(result, []), do: []
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
