defmodule ABSmartly.Murmur3Test do
  use ExUnit.Case, async: true

  alias ABSmartly.Murmur3

  @seed_0 0x00000000
  @seed_deadbeef 0xDEADBEEF
  @seed_1 0x00000001

  # Expected values are independent reference vectors (from the ABsmartly
  # JavaScript SDK murmur3_32 test suite), NOT computed by this implementation.
  @murmur3_test_cases [
    {"", @seed_0, 0x00000000},
    {" ", @seed_0, 0x7EF49B98},
    {"t", @seed_0, 0xCA87DF4D},
    {"te", @seed_0, 0xEDB8EE1B},
    {"tes", @seed_0, 0x0BB90E5A},
    {"test", @seed_0, 0xBA6BD213},
    {"testy", @seed_0, 0x44AF8342},
    {"testy1", @seed_0, 0x8A1A243A},
    {"testy12", @seed_0, 0x845461B9},
    {"testy123", @seed_0, 0x47628AC4},
    {"special characters açb↓c", @seed_0, 0xBE83B140},
    {"The quick brown fox jumps over the lazy dog", @seed_0, 0x2E4FF723},
    {"", @seed_deadbeef, 0x0DE5C6A9},
    {" ", @seed_deadbeef, 0x25ACCE43},
    {"t", @seed_deadbeef, 0x3B15DCF8},
    {"te", @seed_deadbeef, 0xAC981332},
    {"tes", @seed_deadbeef, 0xC1C78DDA},
    {"test", @seed_deadbeef, 0xAA22D41A},
    {"testy", @seed_deadbeef, 0x84F5F623},
    {"testy1", @seed_deadbeef, 0x09ED28E9},
    {"testy12", @seed_deadbeef, 0x22467835},
    {"testy123", @seed_deadbeef, 0xD633060D},
    {"special characters açb↓c", @seed_deadbeef, 0xF7FDD8A2},
    {"The quick brown fox jumps over the lazy dog", @seed_deadbeef, 0x3A7B3F4D},
    {"", @seed_1, 0x514E28B7},
    {" ", @seed_1, 0x4F0F7132},
    {"t", @seed_1, 0x5DB1831E},
    {"te", @seed_1, 0xD248BB2E},
    {"tes", @seed_1, 0xD432EB74},
    {"test", @seed_1, 0x99C02AE2},
    {"testy", @seed_1, 0xC5B2DC1E},
    {"testy1", @seed_1, 0x33925CEB},
    {"testy12", @seed_1, 0xD92C9F23},
    {"testy123", @seed_1, 0x3BC1712D},
    {"special characters açb↓c", @seed_1, 0x293327B5},
    {"The quick brown fox jumps over the lazy dog", @seed_1, 0x78E69E27}
  ]

  describe "hash32/2 should match known hashes" do
    for {input, seed, expected} <- @murmur3_test_cases do
      seed_label =
        case seed do
          0x00000000 -> "0x00000000"
          0xDEADBEEF -> "0xDEADBEEF"
          0x00000001 -> "0x00000001"
        end

      @tag_input input
      @tag_seed seed
      @tag_expected expected
      test "hashes #{inspect(input)} with seed #{seed_label} to #{expected}" do
        assert Murmur3.hash32(@tag_input, @tag_seed) == @tag_expected
      end
    end
  end

  describe "hash32/2 known reference values" do
    test "empty string with seed 0 returns 0" do
      assert Murmur3.hash32("", 0) == 0
    end

    test "test with seed 0 returns 0xBA6BD213" do
      assert Murmur3.hash32("test", 0) == 0xBA6BD213
    end

    test "test with seed 0xDEADBEEF returns 0xAA22D41A" do
      assert Murmur3.hash32("test", 0xDEADBEEF) == 0xAA22D41A
    end
  end
end
