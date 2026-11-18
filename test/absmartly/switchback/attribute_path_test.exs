defmodule ABSmartly.Switchback.AttributePathTest do
  @moduledoc """
  Port of the Java SDK's `SwitchbackAttributePathTest` (java-sdk#15).

  `test/fixtures/switchback/attribute-path-cases.json` is a byte-for-byte
  copy of absmartly/abs 9bd2b5ca35
  `collector/src/test/resources/switchback/attribute-path-cases.json` (git
  blob 7b1d3fed5985), the same file java-sdk vendors.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.Switchback.AttributePath

  @fixture Path.expand("../../fixtures/switchback/attribute-path-cases.json", __DIR__)
  @external_resource @fixture

  defp resolve(path, attributes),
    do: path |> AttributePath.parse_supported() |> AttributePath.resolve(attributes)

  test "the vendored fixture is the Collector's git blob 7b1d3fed5985" do
    content = File.read!(@fixture)
    blob = :crypto.hash(:sha, "blob #{byte_size(content)}\0" <> content)
    assert Base.encode16(blob, case: :lower) == "7b1d3fed59856fcbc296ed68a820b43359ae1932"
  end

  # matchesEveryPathCase
  test "matches every path case" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert length(fixture["cases"]) == 7

    for c <- fixture["cases"] do
      path = AttributePath.parse_supported(c["path"])

      if c["supported"] do
        assert path != nil, inspect(c)
        assert AttributePath.resolve(path, fixture["attributes"]) == c["value"], inspect(c)
      else
        assert path == nil, inspect(c)
      end
    end
  end

  # quotedSegmentsAreLiteralKeys
  test "quoted segments are literal keys" do
    attributes = %{"geo" => %{"0" => "zero", "a/b" => "slash"}}
    assert resolve("geo/'0'", attributes) == "zero"
    assert resolve(~s(geo/"a/b"), attributes) == "slash"
  end

  # rejectsMalformedPaths
  test "rejects malformed paths" do
    for path <- [
          "geo/'0",
          "'geo",
          ~s("geo/city),
          ~s(geo/"),
          "geo.city",
          "geo/a.b",
          "a./b",
          ".",
          "items/0.5/city",
          "'geo.city'",
          ~s("geo.city"),
          "geo/'a.b'"
        ] do
      assert AttributePath.parse_supported(path) == nil, path
    end
  end

  # separatorsAreCollapsed
  test "separators are collapsed" do
    attributes = %{"geo" => %{"city" => "Porto"}}
    assert resolve("/geo//city/", attributes) == "Porto"
    assert resolve("geo", attributes) == attributes["geo"]
  end

  # rejectsUnsupportedPaths
  test "rejects unsupported paths" do
    for path <- [
          nil,
          "",
          "/",
          "//",
          "0/city",
          "items/0",
          "items/0/1/city",
          "items/-1/city",
          "'",
          42
        ] do
      assert AttributePath.parse_supported(path) == nil, inspect(path)
    end
  end

  # indexSegmentsReadOnlyListsAndKeySegmentsReadOnlyMaps
  test "index segments read only lists and key segments read only maps" do
    attributes = %{
      "items" => [%{"city" => "Lisbon"}],
      "geo" => %{"0" => %{"city" => "zero"}},
      "name" => "scalar"
    }

    assert resolve("geo/0/city", attributes) == nil
    assert resolve("items/1/city", attributes) == nil
    assert resolve("name/x", attributes) == nil
    assert resolve("missing/x", attributes) == nil
    assert resolve("items/-0/city", attributes) == "Lisbon"
  end

  # cyclicOrTooDeepValuesHaveNoKey: an Elixir term cannot be cyclic; values
  # with no JSON encoding and values nested past the bound have no key.
  test "unencodable or too deep values have no key" do
    path = AttributePath.parse_supported("geo/city")

    deep =
      Enum.reduce(1..64, %{"leaf" => "x"}, fn _, acc -> %{"city" => "Porto", "next" => acc} end)

    assert AttributePath.resolve_attribute(path, deep) == nil
    assert AttributePath.resolve_attribute(path, deep["next"]) == "Porto"

    shared = %{"a" => "b"}

    assert AttributePath.resolve_attribute(path, %{
             "city" => "Porto",
             "x" => shared,
             "y" => shared
           }) == "Porto"

    for value <- [
          %{"city" => {1, 2}},
          %{"city" => self()},
          %{"city" => <<255>>},
          [1 | 2],
          <<255>>
        ] do
      assert AttributePath.resolve_attribute(path, value) == nil, inspect(value)
    end
  end

  test "attribute values are read through their JSON encoding" do
    path = AttributePath.parse_supported("geo/city")
    assert AttributePath.resolve_attribute(path, %{city: "atom key"}) == "atom key"
    assert AttributePath.resolve_attribute(path, %{"city" => :atom_value}) == "atom_value"
    assert AttributePath.resolve_attribute(path, %{"city" => 42}) == 42
    assert AttributePath.resolve_attribute(path, %{"city" => 3.0}) == 3.0
    assert AttributePath.resolve_attribute(AttributePath.parse_supported("geo"), "Faro") == "Faro"
  end

  # tryParseIntFollowsGuava
  test "try_parse_int follows Guava Ints.tryParse" do
    assert AttributePath.try_parse_int("0") == 0
    assert AttributePath.try_parse_int("-0") == 0
    assert AttributePath.try_parse_int("007") == 7
    assert AttributePath.try_parse_int("2147483647") == 2_147_483_647
    assert AttributePath.try_parse_int("-2147483648") == -2_147_483_648

    for s <- [
          "",
          "-",
          "+1",
          "1a",
          " 1",
          "2147483648",
          "-2147483649",
          "99999999999999999999",
          "٠",
          "1.0"
        ] do
      assert AttributePath.try_parse_int(s) == nil, s
    end
  end
end
