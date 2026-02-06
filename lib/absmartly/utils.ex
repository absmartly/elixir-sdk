defmodule ABSmartly.Utils do
  @moduledoc """
  Utility functions for ABSmartly SDK.
  """

  @doc """
  Hash a unit identifier using MD5 and encode as base64url (no padding).

  ## Examples

      iex> ABSmartly.Utils.hash_unit("bleh@absmartly.com")
      "rcH4hfF5JRm9-sOLmWKubA"
  """
  def hash_unit(uid) when is_binary(uid) do
    :crypto.hash(:md5, uid)
    |> Base.url_encode64(padding: false)
  end

  def hash_unit(uid) when is_integer(uid) do
    hash_unit(Integer.to_string(uid))
  end

  def hash_unit(uid) do
    hash_unit(to_string(uid))
  end

  @doc """
  Choose a variant based on cumulative split probabilities.

  Returns the index of the first variant where cumulative probability >= value.

  ## Examples

      iex> ABSmartly.Utils.choose_variant([0.0, 1.0], 0.0)
      1

      iex> ABSmartly.Utils.choose_variant([0.0, 1.0], 0.5)
      1

      iex> ABSmartly.Utils.choose_variant([0.5, 0.5], 0.0)
      0

      iex> ABSmartly.Utils.choose_variant([0.5, 0.5], 0.5)
      1

      iex> ABSmartly.Utils.choose_variant([0.33, 0.33, 0.34], 0.66)
      2
  """
  def choose_variant(split, probability) when is_list(split) and is_number(probability) do
    do_choose_variant(split, probability, 0, 0.0, length(split))
  end

  defp do_choose_variant([], _probability, _index, _cumulative, split_length) do
    max(split_length - 1, 0)
  end

  defp do_choose_variant([fraction | rest], probability, index, cumulative, split_length) do
    cumulative = cumulative + fraction

    if probability < cumulative do
      index
    else
      do_choose_variant(rest, probability, index + 1, cumulative, split_length)
    end
  end

  @doc """
  Convert any value to a string representation.
  """
  def to_string_value(nil), do: nil
  def to_string_value(val) when is_binary(val), do: val
  def to_string_value(val) when is_integer(val), do: Integer.to_string(val)
  def to_string_value(val) when is_float(val), do: Float.to_string(val)
  def to_string_value(val) when is_boolean(val), do: Atom.to_string(val)
  def to_string_value(val), do: Kernel.to_string(val)

  @doc """
  Convert any value to a number (integer or float).
  Returns nil if conversion fails.
  """
  def to_number(nil), do: nil
  def to_number(n) when is_number(n), do: n
  def to_number(true), do: 1
  def to_number(false), do: 0

  def to_number(""), do: 0.0

  def to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {num, ""} -> num
      _ -> nil
    end
  end

  def to_number(_), do: nil

  @doc """
  Convert any value to a boolean.
  """
  def to_boolean(nil), do: nil
  def to_boolean(false), do: false
  def to_boolean(0), do: false
  def to_boolean(+0.0), do: false
  def to_boolean(""), do: false
  def to_boolean(_), do: true

  @doc """
  Deep copy a value by encoding and decoding JSON.
  """
  def deep_copy(value) do
    case Jason.encode(value) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, decoded} -> decoded
          _ -> value
        end

      _ ->
        value
    end
  end

  @doc """
  Convert snake_case to camelCase.
  """
  def snake_to_camel(string) when is_binary(string) do
    string
    |> String.split("_")
    |> Enum.with_index()
    |> Enum.map(fn {word, idx} ->
      if idx == 0 do
        word
      else
        String.capitalize(word)
      end
    end)
    |> Enum.join()
  end

  def snake_to_camel(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> snake_to_camel()
  end
end
