defmodule ABSmartly.Murmur3 do
  @moduledoc """
  Murmur3_32 hash implementation using the `murmur` library.

  This is a thin wrapper around the well-tested `murmur` hex package,
  which provides a pure Elixir implementation of MurmurHash3.

  CRITICAL: All arithmetic is UNSIGNED 32-bit with LITTLE-ENDIAN byte order.
  The `murmur` library handles this correctly.
  """

  @doc """
  Compute Murmur3_32 hash of binary data using the murmur library.

  ## Examples

      iex> ABSmartly.Murmur3.hash32("", 0)
      0x00000000

      iex> ABSmartly.Murmur3.hash32("absmartly.com", 0)
      0x6D02F2B7

      iex> ABSmartly.Murmur3.hash32("bleh@absmartly.com", 0)
      0x1498CA89
  """
  def hash32(data, seed \\ 0) when is_binary(data) do
    Murmur.hash_x86_32(data, seed)
  end
end
