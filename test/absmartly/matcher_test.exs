defmodule ABSmartly.MatcherTest do
  use ExUnit.Case, async: true

  alias ABSmartly.Matcher

  describe "evaluate/2" do
    test "returns nil on empty audience" do
      assert Matcher.evaluate(nil, %{}) == nil
    end

    test "returns nil if filter not object or array" do
      assert Matcher.evaluate(nil, []) == nil
      assert Matcher.evaluate(nil, %{}) == nil
    end

    test "returns boolean for filter expressions" do
      assert Matcher.evaluate(%{"filter" => [%{"value" => true}]}, %{}) == true
      assert Matcher.evaluate(%{"filter" => [%{"value" => false}]}, %{}) == false
    end

    test "returns true for empty map" do
      assert Matcher.evaluate(%{}, %{}) == true
    end

    test "returns true for map without filter key" do
      assert Matcher.evaluate(%{"something" => "else"}, %{}) == true
    end

    test "evaluates variable comparisons" do
      filter = %{
        "filter" => [
          %{"gte" => [%{"var" => "age"}, %{"value" => 20}]}
        ]
      }

      assert Matcher.evaluate(filter, [%{"name" => "age", "value" => 25}]) == true
      assert Matcher.evaluate(filter, [%{"name" => "age", "value" => 15}]) == false
    end
  end
end
