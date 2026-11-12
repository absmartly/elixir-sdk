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
      assert Matcher.evaluate(%{"filter" => "invalid"}, %{}) == nil
      assert Matcher.evaluate(%{"filter" => 1}, %{}) == nil
    end

    test "evaluates map filter expressions" do
      assert Matcher.evaluate(%{"filter" => %{"value" => true}}, %{}) == true
      assert Matcher.evaluate(%{"filter" => %{"value" => false}}, %{}) == false
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

  describe "parse_rules/1" do
    test "returns the rules list" do
      rules = [%{"type" => "assign", "variant" => 1}]
      assert Matcher.parse_rules(Jason.encode!(%{"rules" => rules})) == rules
    end

    test "returns nil for absent, invalid or malformed rules" do
      for value <- [nil, "", "not json", "null", "[]", "{}", "{\"rules\":{}}", "{\"rules\":1}"] do
        assert Matcher.parse_rules(value) == nil, inspect(value)
      end
    end
  end

  describe "evaluate_rules/3" do
    @us %{"and" => [%{"eq" => [%{"var" => "country"}, %{"value" => "US"}]}]}
    @fallback %{"name" => "fallback", "type" => "assign", "environments" => [], "variant" => 2}

    defp assign_rule(variant, opts \\ []) do
      %{
        "name" => "rule",
        "type" => "assign",
        "conditions" => Keyword.get(opts, :conditions, @us),
        "environments" => Keyword.get(opts, :environments, []),
        "variant" => variant
      }
    end

    defp split_rule(percentages) do
      %{
        "name" => "split",
        "type" => "split",
        "conditions" => @us,
        "environments" => [],
        "percentages" => percentages
      }
    end

    defp evaluate_us(rules, environment \\ "production"),
      do: Matcher.evaluate_rules(rules, environment, %{"country" => "US"})

    test "returns the variant of the first matching assign rule" do
      assert evaluate_us([assign_rule(1), assign_rule(2)]) == {:variant, 1}
      assert evaluate_us([assign_rule(0)]) == {:variant, 0}
    end

    test "returns nil when no rule matches" do
      assert Matcher.evaluate_rules([assign_rule(1)], "production", %{"country" => "GB"}) == nil
      assert Matcher.evaluate_rules([assign_rule(1)], "production", %{}) == nil
      assert evaluate_us([]) == nil
      assert evaluate_us(nil) == nil
    end

    test "accepts attributes as a list of name/value maps" do
      attrs = [%{"name" => "country", "value" => "US"}]
      assert Matcher.evaluate_rules([assign_rule(1)], "production", attrs) == {:variant, 1}
    end

    test "absent or null conditions match everyone" do
      assert evaluate_us([assign_rule(3, conditions: nil)]) == {:variant, 3}
      assert evaluate_us([%{"type" => "assign", "variant" => 3}]) == {:variant, 3}
    end

    test "conditions that are not an object are skipped" do
      assert evaluate_us([assign_rule(1, conditions: "US"), @fallback]) == {:variant, 2}
      assert evaluate_us([assign_rule(1, conditions: [@us]), @fallback]) == {:variant, 2}
    end

    test "conditions are converted to a boolean like the JavaScript SDK" do
      assert evaluate_us([assign_rule(1, conditions: %{"value" => "yes"})]) == {:variant, 1}

      assert evaluate_us([assign_rule(1, conditions: %{"value" => 0}), @fallback]) ==
               {:variant, 2}
    end

    test "environments scope a rule" do
      rule = assign_rule(1, environments: ["production", "staging"])

      assert evaluate_us([rule], "production") == {:variant, 1}
      assert evaluate_us([rule], "staging") == {:variant, 1}
      assert evaluate_us([rule, @fallback], "development") == {:variant, 2}
      assert evaluate_us([rule, @fallback], nil) == {:variant, 2}
    end

    test "empty or absent environments match every environment" do
      assert evaluate_us([assign_rule(1, environments: [])], nil) == {:variant, 1}
      assert evaluate_us([Map.delete(assign_rule(1), "environments")], nil) == {:variant, 1}
    end

    test "environments that are not a list are skipped" do
      assert evaluate_us([assign_rule(1, environments: "production"), @fallback]) ==
               {:variant, 2}
    end

    test "rules with an invalid action are skipped" do
      for rule <- [
            nil,
            "rule",
            %{"type" => "assign"},
            %{"type" => "assign", "variant" => 1.5},
            %{"type" => "assign", "variant" => "1"},
            %{"type" => "other", "variant" => 1},
            %{"variant" => 1}
          ] do
        assert evaluate_us([rule, @fallback]) == {:variant, 2}, inspect(rule)
      end
    end

    test "returns out-of-range variants (bounds checking is the caller's job)" do
      assert evaluate_us([assign_rule(-1)]) == {:variant, -1}
      assert evaluate_us([assign_rule(99)]) == {:variant, 99}
    end

    test "returns a split rule's percentages as fractions" do
      assert evaluate_us([split_rule("20/30/50")]) == {:split, [0.2, 0.3, 0.5]}
      assert evaluate_us([split_rule("33.33/33.33/33.33")]) == {:split, [0.3333, 0.3333, 0.3333]}
      assert evaluate_us([split_rule("100")]) == {:split, [1.0]}
    end

    test "skips a split rule with invalid percentages" do
      for percentages <- [[50, 50], 100, nil, "50/abc", "150/-50", "50/49", "", "Infinity/0"] do
        assert evaluate_us([split_rule(percentages), @fallback]) == {:variant, 2},
               inspect(percentages)
      end
    end

    # Same check as the backend's experiment split: the gap from 100 is rounded
    # to two decimals before being compared with 0.01.
    test "accepts a split whose gap from 100 rounds to 0.01" do
      for percentages <- ["50/50.014", "50/49.986", "50/50.01"] do
        expected =
          percentages
          |> String.split("/")
          |> Enum.map(fn value -> elem(Float.parse(value), 0) / 100 end)

        assert evaluate_us([split_rule(percentages), @fallback]) == {:split, expected},
               percentages
      end
    end

    test "skips a split whose gap from 100 rounds to 0.02" do
      for percentages <- ["50/50.015", "50/49.985", "50/50.02"] do
        assert evaluate_us([split_rule(percentages), @fallback]) == {:variant, 2}, percentages
      end
    end

    test "a non-matching split rule falls through" do
      rules = [split_rule("50/50"), @fallback]
      assert Matcher.evaluate_rules(rules, "production", %{"country" => "GB"}) == {:variant, 2}
    end
  end
end
