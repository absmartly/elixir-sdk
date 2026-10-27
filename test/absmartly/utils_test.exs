defmodule ABSmartly.UtilsTest do
  use ExUnit.Case, async: true

  alias ABSmartly.Utils

  describe "hash_unit/1" do
    test "matches the JavaScript SDK for numbers" do
      assert Utils.hash_unit(126) == Utils.hash_unit("126")
      assert Utils.hash_unit(125.75) == Utils.hash_unit("126")
      assert Utils.unit_to_string(-0.5) == "-1"
    end

    test "diagnostic helpers" do
      assert Utils.base64_url_no_padding("te") == "dGU"
      assert Utils.utf8_bytes("açb") == <<97, 195, 167, 98>>
      assert Utils.object?(%{})
      refute Utils.object?([])
      task = Task.async(fn -> :ok end)
      Task.await(task)
      refute Utils.object?(task)
      assert Utils.numeric?(1.5)
      refute Utils.numeric?("1")
      refute Utils.promise?(%{"then" => "noop"})
      assert Utils.promise?(task)
    end
    test "hashes string unit" do
      result = Utils.hash_unit("bleh@absmartly.com")
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "hashes integer unit" do
      result = Utils.hash_unit(123456789)
      assert is_binary(result)
    end
  end

  describe "choose_variant/2" do
    test "returns correct variant for probability 0" do
      assert Utils.choose_variant([0.0, 1.0], 0.0) == 1
      assert Utils.choose_variant([0.5, 0.5], 0.0) == 0
      assert Utils.choose_variant([0.33, 0.33, 0.34], 0.0) == 0
    end

    test "returns correct variant for 50/50 split" do
      assert Utils.choose_variant([0.5, 0.5], 0.0) == 0
      assert Utils.choose_variant([0.5, 0.5], 0.25) == 0
      assert Utils.choose_variant([0.5, 0.5], 0.49999999) == 0
      assert Utils.choose_variant([0.5, 0.5], 0.5) == 1
      assert Utils.choose_variant([0.5, 0.5], 0.50000001) == 1
      assert Utils.choose_variant([0.5, 0.5], 0.75) == 1
      assert Utils.choose_variant([0.5, 0.5], 1.0) == 1
    end

    test "returns correct variant for three-way split" do
      assert Utils.choose_variant([0.33, 0.33, 0.34], 0.0) == 0
      assert Utils.choose_variant([0.33, 0.33, 0.34], 0.33) == 1
      assert Utils.choose_variant([0.33, 0.33, 0.34], 0.66) == 2
      assert Utils.choose_variant([0.33, 0.33, 0.34], 1.0) == 2
    end

    test "returns correct variant for 0/100 split" do
      assert Utils.choose_variant([0.0, 1.0], 0.5) == 1
      assert Utils.choose_variant([0.0, 1.0], 1.0) == 1
    end
  end

  describe "to_number/1" do
    test "returns nil for nil" do
      assert Utils.to_number(nil) == nil
    end

    test "returns number unchanged" do
      assert Utils.to_number(42) == 42
      assert Utils.to_number(3.14) == 3.14
    end

    test "converts boolean to number" do
      assert Utils.to_number(true) == 1
      assert Utils.to_number(false) == 0
    end

    test "converts string to number" do
      assert Utils.to_number("123") == 123.0
      assert Utils.to_number("3.14") == 3.14
      assert Utils.to_number("") == 0
      assert Utils.to_number("abc") == nil
    end
  end

  describe "to_boolean/1" do
    test "returns nil for nil" do
      assert Utils.to_boolean(nil) == nil
    end

    test "returns false for falsy values" do
      assert Utils.to_boolean(false) == false
      assert Utils.to_boolean(0) == false
      assert Utils.to_boolean(0.0) == false
      assert Utils.to_boolean("") == false
    end

    test "returns true for truthy values" do
      assert Utils.to_boolean(true) == true
      assert Utils.to_boolean(1) == true
      assert Utils.to_boolean("abc") == true
      assert Utils.to_boolean([]) == true
      assert Utils.to_boolean(%{}) == true
    end
  end
end
