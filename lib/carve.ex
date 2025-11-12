defmodule Carve do
  @moduledoc """
  Carve simplifies JSON API development in Phoenix by automatically formatting endpoint outputs with associated links. Define resource relationships with a simple DSL, and let Carve handle link inclusion and query-based filtering, reducing boilerplate and ensuring consistent, flexible API responses.

  It provides functionality for:
  - Rendering JSON endpoints with links automatically
  - Creating index/show methods for views from a DSL
  - Retrieving links between different data types
  - Encoding and decoding IDs using HashIds
  - Configuring the application
  """

  use Application
  require Logger

  @doc """
  Starts the Carve application.

  This function is called automatically by the OTP application behaviour.
  It configures Carve using the configuration returned by `Carve.Config.get/0`.

  ## Returns

  - `{:ok, pid}`: The pid is the process identifier of the started application.
  """
  def start(_type, _args) do
    Logger.info("Starting Carve")

    # Start Cachex for request-scoped caching
    children = [
      {Cachex, name: :carve_cache}
    ]

    opts = [strategy: :one_for_one, name: Carve.Supervisor]
    result = Supervisor.start_link(children, opts)

    configure(Carve.Config.get())
    result
  end

  @doc """
  Configures Carve with the given arguments.

  This function is typically called during application start, but can also be used
  to reconfigure Carve at runtime.

  ## Parameters

  - `args`: A keyword list of configuration options.

  ## Examples

      iex> Carve.configure(salt: "my_salt", min_length: 8)
      :ok

  """
  def configure(args) do
    Logger.info("Configuring Carve")
    hash_ids_config = args
    Carve.HashIds.configure(hash_ids_config)
  end

  @doc """
  Retrieves links for a given module and data or ID(s).

  This function supports various input types:
  - Single integer ID
  - List of integer IDs
  - Single map (data structure)
  - List of maps (data structures)

  ## Parameters

  - `module`: The module to retrieve links for.
  - `data_or_ids`: The data or ID(s) to retrieve links for.

  ## Returns

  A list of link maps, each containing `:type`, `:id`, and `:data` keys.

  ## Examples

      iex> Carve.links(PostJSON, 1)
      [%{type: :user, id: "abc123", data: %{...}}, %{type: :comment, id: "def456", data: %{...}}]

      iex> Carve.links(PostJSON, [1, 2, 3])
      [%{type: :user, id: "abc123", data: %{...}}, %{type: :comment, id: "def456", data: %{...}}, ...]

      iex> Carve.links(PostJSON, %{id: 1, title: "Test Post"})
      [%{type: :user, id: "abc123", data: %{...}}, %{type: :comment, id: "def456", data: %{...}}]

  """
  def links(module, data_or_ids) do
    cond do
      is_integer(data_or_ids) ->
        Carve.Links.get_links_by_id(module, data_or_ids)

      is_list(data_or_ids) and Enum.all?(data_or_ids, &is_integer/1) ->
        Carve.Links.get_links_by_id(module, data_or_ids)

      is_map(data_or_ids) ->
        Carve.Links.get_links_by_data(module, data_or_ids)

      is_list(data_or_ids) and Enum.all?(data_or_ids, &is_map/1) ->
        Carve.Links.get_links_by_data(module, data_or_ids)

      true ->
        []
    end
  end

  @doc """
  Encodes an ID for a given type using HashIds.

  ## Parameters

  - `type`: The type of the ID (as an atom).
  - `id`: The integer ID to encode.

  ## Returns

  A string representing the encoded ID.

  ## Examples

      iex> Carve.encode(:user, 123)
      "abc123def"

  """
  def encode(type, id) when is_atom(type) and is_integer(id) do
    Carve.HashIds.encode(type, id)
  end

  @doc """
  Decodes a hash with a given type using HashIds.

  ## Parameters

  - `type`: The type of the ID (as an atom).
  - `hash`: The string hash to decode.

  ## Returns

  The decoded integer ID.

  ## Examples

      iex> Carve.decode(:user, "abc123def")
      {:ok, 123}

  """
  def decode(type, hash) when is_atom(type) and is_binary(hash) do
    Carve.HashIds.decode(type, hash)
  end

  @doc """
  Decodes a hash without a type using HashIds.

  This function attempts to decode the hash without knowing its type.

  ## Parameters

  - `hash`: The string hash to decode.

  ## Returns

  The decoded integer ID.

  ## Examples

      iex> Carve.decode("abc123def")
      {:ok, 123}

  """
  def decode(hash) when is_binary(hash) do
    Carve.HashIds.decode(hash)
  end

  @doc """
  Parses the include parameter from the query string parameters.

  This function determines if the include parameter was specified and parses it accordingly.

  ## Parameters

  - `params`: The full params map from the controller.

  ## Returns

  - `nil`: If the parameter was not specified (include everything).
  - `[]`: If an empty string was passed.
  - `[atom]`: A list of atoms representing the types to include.

  ## Examples

      iex> Carve.parse_include(%{"include" => "foo,bar"})
      [:foo, :bar]

      iex> Carve.parse_include(%{"include" => ""})
      []

      iex> Carve.parse_include(%{})
      nil
  """
  def parse_include(params) do
    if include_param_specified?(params) do
      case params["include"] do
        nil ->
          nil

        "" ->
          []

        string when is_binary(string) ->
          string
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.map(&String.to_existing_atom/1)
      end
    else
      nil
    end
  end

  @doc """
  Determines if the include parameter was specified in the query string.

  ## Parameters

  - `params`: The full params map from the controller.

  ## Returns

  - `true`: If the include parameter was specified (even if empty).
  - `false`: If the include parameter was not specified at all.

  ## Examples

      iex> Carve.include_param_specified?(%{"include" => "foo,bar"})
      true

      iex> Carve.include_param_specified?(%{"include" => ""})
      true

      iex> Carve.include_param_specified?(%{})
      false

  """
  def include_param_specified?(params) do
    Map.has_key?(params, "include")
  end
end
