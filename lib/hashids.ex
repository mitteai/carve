defmodule Carve.HashIds do
  @moduledoc """
  Carve.HashIds provides functionality for encoding and decoding IDs using HashIds.

  This module is responsible for:
  - Configuring the HashIds settings
  - Encoding integer IDs into hashed strings
  - Decoding hashed strings back into integer IDs
  - Handling entity-specific salting for added security

  It uses the Hashids library internally and provides a convenient API for Carve users.
  """

  @alphabet "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
  @default_min_length 4
  @default_salt "1207:Rumi"

  @doc """
  Configures the HashIds settings.

  This function sets up the salt and minimum length for HashIds encoding.
  It stores these settings in persistent term storage for efficient access.

  ## Parameters

  - `opts`: A keyword list of configuration options.
    - `:salt` - The salt used for hashing (default: #{@default_salt})
    - `:min_length` - The minimum length of generated hashes (default: #{@default_min_length})

  ## Example

      iex> Carve.HashIds.configure(salt: "my_custom_salt", min_length: 8)
      :ok
  """
  def configure(opts) do
    salt = Keyword.get(opts, :salt, @default_salt)
    min_length = Keyword.get(opts, :min_length, @default_min_length)
    :persistent_term.put(:carve_hash_ids_salt, salt)
    :persistent_term.put(:carve_hash_ids_min_length, min_length)

    # Build the Hashids context once — Hashids.new validates and shuffles the
    # alphabet, far too expensive to repeat on every encode/decode call.
    :persistent_term.put(
      :carve_hash_ids_provider,
      Hashids.new(salt: salt, min_len: min_length, alphabet: @alphabet)
    )
  end

  @doc """
  Encodes an integer ID for a given type into a hashed string.

  ## Parameters

  - `type`: An atom representing the entity type (e.g., :user, :post)
  - `id`: The integer ID to be encoded

  ## Returns

  A string representing the encoded ID.

  ## Example

      iex> Carve.HashIds.encode(:user, 123)
      "Xk9Lp2Rr4m"
  """
  def encode(type, id) when is_atom(type) and is_integer(id) do
    hashids = provider()
    entity_salt = entity_salt(type)
    Hashids.encode(hashids, [id, entity_salt])
  end

  @doc """
  Decodes a hashed string back into an integer ID for a given type.

  ## Parameters

  - `type`: An atom representing the entity type (e.g., :user, :post)
  - `hash`: The hashed string to be decoded

  ## Returns

  `{:ok, id}` if decoding is successful, where `id` is the original integer ID.
  `{:error, :invalid_entity_type}` if the decoded salt doesn't match the given type.
  `{:error, reason}` for other decoding errors.

  ## Example

      iex> Carve.HashIds.decode(:user, "Xk9Lp2Rr4m")
      {:ok, 123}
  """
  def decode(type, hash) when is_atom(type) and is_binary(hash) do
    hashids = provider()
    entity_salt = entity_salt(type)
    case Hashids.decode(hashids, hash) do
      {:ok, [id, ^entity_salt]} -> {:ok, id}
      {:ok, _} -> {:error, :invalid_entity_type}
      {:error, _} = error -> error
    end
  end

  @doc """
  Decodes a hashed string without specifying the entity type.

  This function attempts to decode the hash without verifying the entity type.

  ## Parameters

  - `hash`: The hashed string to be decoded

  ## Returns

  `{:ok, id}` if decoding is successful, where `id` is the original integer ID.
  `{:error, reason}` for decoding errors.

  ## Example

      iex> Carve.HashIds.decode("Xk9Lp2Rr4m")
      {:ok, 123}
  """
  def decode(hash) when is_binary(hash) do
    hashids = provider()
    case Hashids.decode(hashids, hash) do
      {:ok, [id | _]} -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  defp entity_salt(type) do
    type
    |> Atom.to_string()
    |> :erlang.phash2()
  end

  defp provider do
    case :persistent_term.get(:carve_hash_ids_provider, nil) do
      nil ->
        # configure/1 not called yet — build once from the stored settings
        # and memoize.
        salt = :persistent_term.get(:carve_hash_ids_salt)
        min_length = :persistent_term.get(:carve_hash_ids_min_length)
        hashids = Hashids.new(salt: salt, min_len: min_length, alphabet: @alphabet)
        :persistent_term.put(:carve_hash_ids_provider, hashids)
        hashids

      hashids ->
        hashids
    end
  end
end
