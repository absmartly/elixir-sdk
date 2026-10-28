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
  def hash_unit(uid) do
    :crypto.hash(:md5, utf8_bytes(unit_to_string(uid)))
    |> base64_url_no_padding()
  end

  @doc """
  The string form of a unit UID used for hashing. Like the JavaScript SDK
  (`value.toFixed(0)`), a numeric UID is rounded to an integer first.

      iex> ABSmartly.Utils.unit_to_string(125.75)
      "126"
  """
  def unit_to_string(uid) when is_binary(uid), do: uid
  def unit_to_string(uid) when is_number(uid), do: number_to_fixed(uid, 0)
  def unit_to_string(uid), do: to_string(uid)

  @doc false
  def number_to_fixed(number, decimals) do
    number = number * 1.0

    if abs(number) >= 1.0e21 do
      [mantissa, exponent] = String.split(:erlang.float_to_binary(number, [:short]), "e")
      exponent = if String.starts_with?(exponent, "-"), do: exponent, else: "+" <> exponent
      String.replace_suffix(mantissa, ".0", "") <> "e" <> exponent
    else
      # toFixed rounds the exact binary value, not an intermediate decimal approximation.
      {numerator, denominator} = Float.ratio(abs(number))
      scale = Integer.pow(10, decimals)
      scaled = numerator * scale

      rounded =
        div(scaled, denominator) + if(rem(scaled, denominator) * 2 >= denominator, do: 1, else: 0)

      digits = rounded |> Integer.to_string() |> String.pad_leading(decimals + 1, "0")

      fixed =
        if decimals == 0,
          do: digits,
          else:
            String.slice(digits, 0..(-decimals - 1)//1) <>
              "." <> String.slice(digits, -decimals, decimals)

      if number < 0, do: "-" <> fixed, else: fixed
    end
  end

  @doc """
  Encode binary data as base64url without padding.

      iex> ABSmartly.Utils.base64_url_no_padding("te")
      "dGU"
  """
  def base64_url_no_padding(data) when is_binary(data),
    do: Base.url_encode64(data, padding: false)

  @doc """
  The UTF-8 bytes of a string, as a binary.
  """
  def utf8_bytes(value) when is_binary(value), do: value

  @doc """
  True when the value is a plain object (a map that is not a struct).
  """
  def object?(%{__struct__: _}), do: false
  def object?(value), do: is_map(value)

  @doc """
  True when the value is a number.
  """
  def numeric?(value), do: is_number(value)

  @doc """
  True when the value is an asynchronous result (a `Task`), the Elixir
  counterpart of a JavaScript promise.
  """
  def promise?(%Task{}), do: true
  def promise?(_), do: false

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
  Convert any value to a number (integer or float).
  Returns nil if conversion fails.
  """
  def to_number(nil), do: nil
  def to_number(n) when is_number(n), do: n
  def to_number(true), do: 1
  def to_number(false), do: 0

  def to_number(""), do: 0

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
end
