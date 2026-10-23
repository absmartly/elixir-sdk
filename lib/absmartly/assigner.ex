defmodule ABSmartly.VariantAssigner do
  @moduledoc """
  Assigns variants to units based on experiment configuration.

  CRITICAL: Unit must be hashed with hash_unit() BEFORE creating VariantAssigner.
  """

  alias ABSmartly.{Murmur3, Utils}

  @doc """
  Assign a variant for a hashed unit.

  ## Parameters

    * `hashed_unit` - Unit identifier already hashed with Utils.hash_unit()
    * `split` - Array of cumulative split probabilities (e.g., [0.5, 0.5])
    * `seed_hi` - High 32 bits of seed
    * `seed_lo` - Low 32 bits of seed

  ## Examples

      iex> hashed = ABSmartly.Utils.hash_unit("bleh@absmartly.com")
      iex> ABSmartly.VariantAssigner.assign(hashed, [0.5, 0.5], 0, 0)
      0

      iex> hashed = ABSmartly.Utils.hash_unit("bleh@absmartly.com")
      iex> ABSmartly.VariantAssigner.assign(hashed, [0.5, 0.5], 0, 1)
      1

      iex> hashed = ABSmartly.Utils.hash_unit("123456789")
      iex> ABSmartly.VariantAssigner.assign(hashed, [0.5, 0.5], 0, 0)
      1
  """
  def assign(hashed_unit, split, seed_hi, seed_lo)
      when is_binary(hashed_unit) and is_list(split) and
             is_integer(seed_hi) and is_integer(seed_lo) do
    # Compute unit hash
    unit_hash = Murmur3.hash32(hashed_unit, 0)

    # Build buffer: [seedLo (4 bytes LE), seedHi (4 bytes LE), unitHash (4 bytes LE)]
    buffer =
      <<seed_lo::little-unsigned-32, seed_hi::little-unsigned-32, unit_hash::little-unsigned-32>>

    # Hash the buffer
    hash = Murmur3.hash32(buffer, 0)

    # Compute probability (CRITICAL: divide by 0xFFFFFFFF, NOT 0x100000000)
    probability = hash / 0xFFFFFFFF

    # Choose variant based on split
    Utils.choose_variant(split, probability)
  end
end
