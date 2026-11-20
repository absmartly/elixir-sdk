defmodule ABSmartly.Switchback.Assigner do
  @moduledoc false
  # Balanced-block switchback assignment. Port of the Java SDK's
  # internal.SwitchbackAssigner (java-sdk#15), itself a port of the platform's
  # SwitchbackAssignment (Guava murmur3_32_fixed, seed 0):
  #
  #   key       = utf8(clusterUnit <> "\u001f" <> cycleIndex)
  #   baseHash  = murmur3_32(le64(seed) ++ le32(murmur3_32(key)))
  #   stepHash  = murmur3_32(le32(baseHash) ++ le32(i)),  i = armCount-1 .. 1
  #   j         = min(i, floor(u32(stepHash) * (1 / 0xffffffff) * (i + 1)))
  #   variant   = permutation[floorMod(periodIndex, armCount)], cycle = floorDiv(periodIndex, armCount)
  #
  # periodIndex, cycleIndex and seed are signed 64-bit values. Elixir integers
  # are exact, so floorDiv/floorMod never wrap; the seed is reduced to its low
  # 64 bits. Any change here breaks parity with the platform golden vectors
  # (test/fixtures/switchback/golden-vectors.json).

  import Bitwise

  alias ABSmartly.Murmur3

  @normalizer 1.0 / 0xFFFFFFFF
  @separator "\u001f"

  @doc false
  def assign(cluster_unit, period_index, seed, arm_count)
      when is_binary(cluster_unit) and is_integer(period_index) and is_integer(seed) do
    require_valid_arm_count!(arm_count)
    cycle_index = Integer.floor_div(period_index, arm_count)
    cycle_slot = Integer.mod(period_index, arm_count)

    arm_count
    |> fisher_yates_permutation(base_hash(cluster_unit, cycle_index, seed))
    |> elem(cycle_slot)
  end

  @doc false
  def base_hash(cluster_unit, cycle_index, seed)
      when is_binary(cluster_unit) and is_integer(cycle_index) and is_integer(seed) do
    key_hash = Murmur3.hash32(cluster_unit <> @separator <> Integer.to_string(cycle_index), 0)

    Murmur3.hash32(
      <<band(seed, 0xFFFFFFFFFFFFFFFF)::little-64, key_hash::little-32>>,
      0
    )
  end

  @doc false
  def fisher_yates_permutation(arm_count, base_hash) when is_integer(base_hash) do
    require_valid_arm_count!(arm_count)

    Enum.reduce((arm_count - 1)..1//-1, List.to_tuple(Enum.to_list(0..(arm_count - 1))), fn i,
                                                                                            perm ->
      step_hash = Murmur3.hash32(<<band(base_hash, 0xFFFFFFFF)::little-32, i::little-32>>, 0)
      # prob == 1.0 would map to i + 1
      j = min(i, floor(step_hash * @normalizer * (i + 1)))
      at_i = elem(perm, i)
      perm |> put_elem(i, elem(perm, j)) |> put_elem(j, at_i)
    end)
  end

  defp require_valid_arm_count!(arm_count) when is_integer(arm_count) and arm_count >= 2, do: :ok

  defp require_valid_arm_count!(arm_count),
    do: raise(ArgumentError, "armCount must be >= 2, got #{inspect(arm_count)}")
end
