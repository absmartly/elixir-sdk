defmodule ABSmartly.Switchback.AssignerGoldenVectorsTest do
  @moduledoc """
  Port of the Java SDK's `SwitchbackAssignerGoldenVectorsTest` (java-sdk#15).

  `test/fixtures/switchback/golden-vectors.json` is a byte-for-byte copy of
  absmartly/abs 9bd2b5ca35 `lib/utils/src/test/resources/switchback/golden-vectors.json`
  (git blob b314abeb9e97), the same file java-sdk vendors at
  `core-api/src/test/resources/switchback/golden-vectors.json`.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.Switchback.Assigner, as: SwitchbackAssigner

  @fixture Path.expand("../../fixtures/switchback/golden-vectors.json", __DIR__)
  @external_resource @fixture
  @vectors @fixture |> File.read!() |> Jason.decode!()

  @long_min -0x8000000000000000
  @long_max 0x7FFFFFFFFFFFFFFF

  # The platform keys a numeric cluster unit as Long.toString(n); strings pass through.
  defp cluster_unit(unit) when is_integer(unit), do: Integer.to_string(unit)
  defp cluster_unit(unit) when is_binary(unit), do: unit

  # 64-bit fields are decimal strings; a number would mean the fixture
  # regressed to a lossy encoding.
  defp exact_long(value) when is_binary(value), do: String.to_integer(value)

  test "the vendored fixture is the platform's git blob b314abeb9e97" do
    content = File.read!(@fixture)
    blob = :crypto.hash(:sha, "blob #{byte_size(content)}\0" <> content)
    assert Base.encode16(blob, case: :lower) == "b314abeb9e97b35f911c7caacec90b8ff73b9d77"
  end

  test "assign matches every golden vector" do
    cases = @vectors["assignSwitchback"]
    assert length(cases) == 882

    boundary =
      Enum.count(cases, fn c ->
        period = exact_long(c["periodIndex"])
        seed = exact_long(c["seed"])

        assert SwitchbackAssigner.assign(
                 cluster_unit(c["clusterUnit"]),
                 period,
                 seed,
                 c["armCount"]
               ) == c["expectedVariant"],
               inspect(c)

        period in [@long_min, @long_max] or seed in [@long_min, @long_max]
      end)

    assert cases |> Enum.map(& &1["armCount"]) |> Enum.uniq() |> Enum.sort() == [2, 3, 10]
    assert boundary > 0
  end

  test "fisher_yates_permutation matches every golden vector" do
    cases = @vectors["fisherYatesPermutation"]
    assert length(cases) == 504

    for c <- cases do
      base =
        SwitchbackAssigner.base_hash(
          cluster_unit(c["clusterUnit"]),
          exact_long(c["cycleIndex"]),
          exact_long(c["seed"])
        )

      assert Tuple.to_list(SwitchbackAssigner.fisher_yates_permutation(c["armCount"], base)) ==
               c["expectedPermutation"],
             inspect(c)
    end
  end

  test "every cycle covers every arm exactly once" do
    for arm_count <- [2, 3, 10], cycle <- -3..19 do
      variants =
        for slot <- 0..(arm_count - 1),
            do:
              SwitchbackAssigner.assign(
                "store_42",
                cycle * arm_count + slot,
                0x123456789ABC,
                arm_count
              )

      assert Enum.sort(variants) == Enum.to_list(0..(arm_count - 1))
    end
  end

  test "rejects fewer than two arms" do
    assert_raise ArgumentError, fn -> SwitchbackAssigner.assign("u", 0, 0, 1) end
    assert_raise ArgumentError, fn -> SwitchbackAssigner.fisher_yates_permutation(0, 0) end
  end
end
