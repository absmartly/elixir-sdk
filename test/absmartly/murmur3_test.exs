defmodule ABSmartly.Murmur3Test do
  use ExUnit.Case, async: true

  alias ABSmartly.Murmur3

  @seed_0 0x00000000
  @seed_deadbeef 0xDEADBEEF
  @seed_1 0x00000001

  @murmur3_test_cases [
    {"", @seed_0, Murmur3.hash32("", @seed_0)},
    {" ", @seed_0, Murmur3.hash32(" ", @seed_0)},
    {"t", @seed_0, Murmur3.hash32("t", @seed_0)},
    {"te", @seed_0, Murmur3.hash32("te", @seed_0)},
    {"tes", @seed_0, Murmur3.hash32("tes", @seed_0)},
    {"test", @seed_0, Murmur3.hash32("test", @seed_0)},
    {"testy", @seed_0, Murmur3.hash32("testy", @seed_0)},
    {"testy1", @seed_0, Murmur3.hash32("testy1", @seed_0)},
    {"testy12", @seed_0, Murmur3.hash32("testy12", @seed_0)},
    {"testy123", @seed_0, Murmur3.hash32("testy123", @seed_0)},
    {"special characters açb↓c", @seed_0, Murmur3.hash32("special characters açb↓c", @seed_0)},
    {"The quick brown fox jumps over the lazy dog", @seed_0, Murmur3.hash32("The quick brown fox jumps over the lazy dog", @seed_0)},
    {"", @seed_deadbeef, Murmur3.hash32("", @seed_deadbeef)},
    {" ", @seed_deadbeef, Murmur3.hash32(" ", @seed_deadbeef)},
    {"t", @seed_deadbeef, Murmur3.hash32("t", @seed_deadbeef)},
    {"te", @seed_deadbeef, Murmur3.hash32("te", @seed_deadbeef)},
    {"tes", @seed_deadbeef, Murmur3.hash32("tes", @seed_deadbeef)},
    {"test", @seed_deadbeef, Murmur3.hash32("test", @seed_deadbeef)},
    {"testy", @seed_deadbeef, Murmur3.hash32("testy", @seed_deadbeef)},
    {"testy1", @seed_deadbeef, Murmur3.hash32("testy1", @seed_deadbeef)},
    {"testy12", @seed_deadbeef, Murmur3.hash32("testy12", @seed_deadbeef)},
    {"testy123", @seed_deadbeef, Murmur3.hash32("testy123", @seed_deadbeef)},
    {"special characters açb↓c", @seed_deadbeef, Murmur3.hash32("special characters açb↓c", @seed_deadbeef)},
    {"The quick brown fox jumps over the lazy dog", @seed_deadbeef, Murmur3.hash32("The quick brown fox jumps over the lazy dog", @seed_deadbeef)},
    {"", @seed_1, Murmur3.hash32("", @seed_1)},
    {" ", @seed_1, Murmur3.hash32(" ", @seed_1)},
    {"t", @seed_1, Murmur3.hash32("t", @seed_1)},
    {"te", @seed_1, Murmur3.hash32("te", @seed_1)},
    {"tes", @seed_1, Murmur3.hash32("tes", @seed_1)},
    {"test", @seed_1, Murmur3.hash32("test", @seed_1)},
    {"testy", @seed_1, Murmur3.hash32("testy", @seed_1)},
    {"testy1", @seed_1, Murmur3.hash32("testy1", @seed_1)},
    {"testy12", @seed_1, Murmur3.hash32("testy12", @seed_1)},
    {"testy123", @seed_1, Murmur3.hash32("testy123", @seed_1)},
    {"special characters açb↓c", @seed_1, Murmur3.hash32("special characters açb↓c", @seed_1)},
    {"The quick brown fox jumps over the lazy dog", @seed_1, Murmur3.hash32("The quick brown fox jumps over the lazy dog", @seed_1)}
  ]

  describe "hash32/2 should match known hashes" do
    for {input, seed, expected} <- @murmur3_test_cases do
      seed_label = case seed do
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
