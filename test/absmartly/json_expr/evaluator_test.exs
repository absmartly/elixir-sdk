defmodule ABSmartly.JSONExpr.EvaluatorTest do
  use ExUnit.Case, async: true

  alias ABSmartly.JSONExpr.Evaluator

  describe "evaluate/2" do
    test "returns nil for nil expression" do
      assert Evaluator.evaluate(nil, %{}) == nil
    end

    test "returns nil for non-map non-list expressions" do
      assert Evaluator.evaluate(42, %{}) == nil
      assert Evaluator.evaluate("hello", %{}) == nil
      assert Evaluator.evaluate(true, %{}) == nil
      assert Evaluator.evaluate(false, %{}) == nil
    end

    test "returns nil when no recognized operator" do
      assert Evaluator.evaluate(%{"unknown" => 42}, %{}) == nil
    end

    test "treats array as implicit AND" do
      assert Evaluator.evaluate([%{"value" => true}, %{"value" => true}], %{}) == true
      assert Evaluator.evaluate([%{"value" => true}, %{"value" => false}], %{}) == false
    end
  end

  describe "value operator" do
    test "returns the value" do
      assert Evaluator.evaluate(%{"value" => true}, %{}) == true
      assert Evaluator.evaluate(%{"value" => false}, %{}) == false
      assert Evaluator.evaluate(%{"value" => 42}, %{}) == 42
      assert Evaluator.evaluate(%{"value" => "hello"}, %{}) == "hello"
      assert Evaluator.evaluate(%{"value" => nil}, %{}) == nil
    end
  end

  describe "var operator" do
    test "extracts simple variables" do
      vars = %{"a" => 1, "b" => true, "c" => "hello"}
      assert Evaluator.evaluate(%{"var" => "a"}, vars) == 1
      assert Evaluator.evaluate(%{"var" => "b"}, vars) == true
      assert Evaluator.evaluate(%{"var" => "c"}, vars) == "hello"
    end

    test "extracts nested variables with path" do
      vars = %{"f" => %{"y" => %{"x" => 3}}}
      assert Evaluator.evaluate(%{"var" => "f/y/x"}, vars) == 3
      assert Evaluator.evaluate(%{"var" => "f/y"}, vars) == %{"x" => 3}
    end

    test "extracts array elements by index" do
      vars = %{"d" => [1, 2, 3]}
      assert Evaluator.evaluate(%{"var" => "d/0"}, vars) == 1
      assert Evaluator.evaluate(%{"var" => "d/1"}, vars) == 2
      assert Evaluator.evaluate(%{"var" => "d/2"}, vars) == 3
      assert Evaluator.evaluate(%{"var" => "d/3"}, vars) == nil
    end

    test "extracts nested array objects" do
      vars = %{"e" => [1, %{"z" => 2}, 3]}
      assert Evaluator.evaluate(%{"var" => "e/1/z"}, vars) == 2
    end

    test "returns nil for non-existent paths" do
      vars = %{"a" => 1}
      assert Evaluator.evaluate(%{"var" => "b"}, vars) == nil
      assert Evaluator.evaluate(%{"var" => "a/0"}, vars) == nil
    end

    test "returns nil for non-string var" do
      assert Evaluator.evaluate(%{"var" => 42}, %{}) == nil
    end
  end

  describe "and operator" do
    test "returns true when all expressions are truthy" do
      expr = %{"and" => [%{"value" => true}, %{"value" => 1}, %{"value" => "abc"}]}
      assert Evaluator.evaluate(expr, %{}) == true
    end

    test "returns false when any expression is falsy" do
      expr = %{"and" => [%{"value" => true}, %{"value" => false}, %{"value" => "abc"}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "returns true for empty list" do
      assert Evaluator.evaluate(%{"and" => []}, %{}) == true
    end

    test "short-circuits on false" do
      expr = %{"and" => [%{"value" => false}, %{"value" => true}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "returns nil when encountering nil" do
      expr = %{"and" => [%{"value" => nil}]}
      assert Evaluator.evaluate(expr, %{}) == nil
    end
  end

  describe "or operator" do
    test "returns true when any expression is truthy" do
      expr = %{"or" => [%{"value" => false}, %{"value" => true}]}
      assert Evaluator.evaluate(expr, %{}) == true
    end

    test "returns false when all expressions are falsy" do
      expr = %{"or" => [%{"value" => false}, %{"value" => 0}, %{"value" => ""}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "returns false for empty list" do
      assert Evaluator.evaluate(%{"or" => []}, %{}) == false
    end

    test "short-circuits on true" do
      expr = %{"or" => [%{"value" => true}, %{"value" => false}]}
      assert Evaluator.evaluate(expr, %{}) == true
    end

    test "returns nil when encountering nil" do
      expr = %{"or" => [%{"value" => nil}]}
      assert Evaluator.evaluate(expr, %{}) == nil
    end
  end

  describe "not operator" do
    test "negates boolean" do
      assert Evaluator.evaluate(%{"not" => %{"value" => true}}, %{}) == false
      assert Evaluator.evaluate(%{"not" => %{"value" => false}}, %{}) == true
    end

    test "negates truthy values" do
      assert Evaluator.evaluate(%{"not" => %{"value" => 1}}, %{}) == false
      assert Evaluator.evaluate(%{"not" => %{"value" => 0}}, %{}) == true
      assert Evaluator.evaluate(%{"not" => %{"value" => "abc"}}, %{}) == false
      assert Evaluator.evaluate(%{"not" => %{"value" => ""}}, %{}) == true
    end

    test "returns nil for nil" do
      assert Evaluator.evaluate(%{"not" => %{"value" => nil}}, %{}) == nil
    end
  end

  describe "null operator" do
    test "returns true for nil" do
      assert Evaluator.evaluate(%{"null" => %{"value" => nil}}, %{}) == true
    end

    test "returns false for non-nil" do
      assert Evaluator.evaluate(%{"null" => %{"value" => 1}}, %{}) == false
      assert Evaluator.evaluate(%{"null" => %{"value" => ""}}, %{}) == false
      assert Evaluator.evaluate(%{"null" => %{"value" => false}}, %{}) == false
    end

    test "returns true for undefined variable" do
      assert Evaluator.evaluate(%{"null" => %{"var" => "missing"}}, %{}) == true
    end
  end

  describe "eq operator" do
    test "compares equal values" do
      assert Evaluator.evaluate(%{"eq" => [%{"value" => 1}, %{"value" => 1}]}, %{}) == true
      assert Evaluator.evaluate(%{"eq" => [%{"value" => "abc"}, %{"value" => "abc"}]}, %{}) == true
      assert Evaluator.evaluate(%{"eq" => [%{"value" => true}, %{"value" => true}]}, %{}) == true
      assert Evaluator.evaluate(%{"eq" => [%{"value" => nil}, %{"value" => nil}]}, %{}) == true
    end

    test "compares unequal values" do
      assert Evaluator.evaluate(%{"eq" => [%{"value" => 1}, %{"value" => 2}]}, %{}) == false
      assert Evaluator.evaluate(%{"eq" => [%{"value" => "abc"}, %{"value" => "def"}]}, %{}) == false
      assert Evaluator.evaluate(%{"eq" => [%{"value" => true}, %{"value" => false}]}, %{}) == false
    end

    test "returns false for incomparable types" do
      assert Evaluator.evaluate(%{"eq" => [%{"value" => 1}, %{"value" => nil}]}, %{}) == false
      assert Evaluator.evaluate(%{"eq" => [%{"value" => nil}, %{"value" => 1}]}, %{}) == false
    end
  end

  describe "gt operator" do
    test "compares greater values" do
      assert Evaluator.evaluate(%{"gt" => [%{"value" => 2}, %{"value" => 1}]}, %{}) == true
      assert Evaluator.evaluate(%{"gt" => [%{"value" => 1}, %{"value" => 2}]}, %{}) == false
      assert Evaluator.evaluate(%{"gt" => [%{"value" => 1}, %{"value" => 1}]}, %{}) == false
    end

    test "compares strings" do
      assert Evaluator.evaluate(%{"gt" => [%{"value" => "bcd"}, %{"value" => "abc"}]}, %{}) == true
      assert Evaluator.evaluate(%{"gt" => [%{"value" => "abc"}, %{"value" => "bcd"}]}, %{}) == false
    end
  end

  describe "gte operator" do
    test "compares greater or equal values" do
      assert Evaluator.evaluate(%{"gte" => [%{"value" => 2}, %{"value" => 1}]}, %{}) == true
      assert Evaluator.evaluate(%{"gte" => [%{"value" => 1}, %{"value" => 1}]}, %{}) == true
      assert Evaluator.evaluate(%{"gte" => [%{"value" => 1}, %{"value" => 2}]}, %{}) == false
    end
  end

  describe "lt operator" do
    test "compares less values" do
      assert Evaluator.evaluate(%{"lt" => [%{"value" => 1}, %{"value" => 2}]}, %{}) == true
      assert Evaluator.evaluate(%{"lt" => [%{"value" => 2}, %{"value" => 1}]}, %{}) == false
      assert Evaluator.evaluate(%{"lt" => [%{"value" => 1}, %{"value" => 1}]}, %{}) == false
    end
  end

  describe "lte operator" do
    test "compares less or equal values" do
      assert Evaluator.evaluate(%{"lte" => [%{"value" => 1}, %{"value" => 2}]}, %{}) == true
      assert Evaluator.evaluate(%{"lte" => [%{"value" => 1}, %{"value" => 1}]}, %{}) == true
      assert Evaluator.evaluate(%{"lte" => [%{"value" => 2}, %{"value" => 1}]}, %{}) == false
    end
  end

  describe "in operator" do
    test "checks string containment" do
      expr = %{"in" => [%{"value" => "bc"}, %{"value" => "abcd"}]}
      assert Evaluator.evaluate(expr, %{}) == true
    end

    test "checks string not contained" do
      expr = %{"in" => [%{"value" => "xyz"}, %{"value" => "abcd"}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "checks array containment" do
      expr = %{"in" => [%{"value" => 2}, %{"value" => [1, 2, 3]}]}
      assert Evaluator.evaluate(expr, %{}) == true
    end

    test "checks array not contained" do
      expr = %{"in" => [%{"value" => 4}, %{"value" => [1, 2, 3]}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "returns false for nil needle" do
      expr = %{"in" => [%{"value" => nil}, %{"value" => [1, 2]}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "returns false for nil haystack" do
      expr = %{"in" => [%{"value" => 1}, %{"value" => nil}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end
  end

  describe "match operator" do
    test "matches regex pattern" do
      expr = %{"match" => [%{"value" => "hello world"}, %{"value" => "hel.*rld"}]}
      assert Evaluator.evaluate(expr, %{}) == true
    end

    test "does not match non-matching pattern" do
      expr = %{"match" => [%{"value" => "hello world"}, %{"value" => "^xyz$"}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "returns false for nil text" do
      expr = %{"match" => [%{"value" => nil}, %{"value" => "pattern"}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "returns false for nil pattern" do
      expr = %{"match" => [%{"value" => "text"}, %{"value" => nil}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end

    test "returns false for invalid regex" do
      expr = %{"match" => [%{"value" => "text"}, %{"value" => "[invalid"}]}
      assert Evaluator.evaluate(expr, %{}) == false
    end
  end

  describe "compare/2" do
    test "nil comparisons" do
      assert Evaluator.compare(nil, nil) == 0
      assert Evaluator.compare(nil, 0) == nil
      assert Evaluator.compare(nil, true) == nil
      assert Evaluator.compare(nil, "") == nil
      assert Evaluator.compare(0, nil) == nil
      assert Evaluator.compare(true, nil) == nil
      assert Evaluator.compare("", nil) == nil
    end

    test "boolean comparisons" do
      assert Evaluator.compare(true, true) == 0
      assert Evaluator.compare(false, false) == 0
      assert Evaluator.compare(true, false) == 1
      assert Evaluator.compare(false, true) == -1
    end

    test "number comparisons" do
      assert Evaluator.compare(0, 0) == 0
      assert Evaluator.compare(1, 1) == 0
      assert Evaluator.compare(2, 1) == 1
      assert Evaluator.compare(1, 2) == -1
      assert Evaluator.compare(1.5, 1) == 1
      assert Evaluator.compare(1, 1.5) == -1
    end

    test "string comparisons" do
      assert Evaluator.compare("", "") == 0
      assert Evaluator.compare("abc", "abc") == 0
      assert Evaluator.compare("bcd", "abc") == 1
      assert Evaluator.compare("abc", "bcd") == -1
    end

    test "incomparable type pairs return nil" do
      assert Evaluator.compare(1, "abc") == nil
      assert Evaluator.compare("abc", 1) == nil
      assert Evaluator.compare(true, "abc") == nil
      assert Evaluator.compare(1, true) == nil
    end
  end

  describe "complex audience expressions" do
    setup do
      john = %{"age" => 20, "language" => "en-US", "returning" => false}
      terry = %{"age" => 20, "language" => "en-GB", "returning" => true}
      kate = %{"age" => 50, "language" => "es-ES", "returning" => false}
      maria = %{"age" => 52, "language" => "pt-PT", "returning" => true}

      age_twenty_and_us = [
        %{"eq" => [%{"var" => "age"}, %{"value" => 20}]},
        %{"eq" => [%{"var" => "language"}, %{"value" => "en-US"}]}
      ]

      age_over_fifty = [%{"gte" => [%{"var" => "age"}, %{"value" => 50}]}]

      age_twenty_and_us_or_over_fifty = [
        %{"or" => [age_twenty_and_us, age_over_fifty]}
      ]

      returning = [%{"eq" => [%{"var" => "returning"}, %{"value" => true}]}]

      returning_and_age_twenty_and_us_or_over_fifty = [
        returning,
        age_twenty_and_us_or_over_fifty
      ] |> List.flatten()

      not_returning_and_spanish = [
        %{"not" => returning},
        %{"eq" => [%{"var" => "language"}, %{"value" => "es-ES"}]}
      ]

      %{
        john: john,
        terry: terry,
        kate: kate,
        maria: maria,
        age_twenty_and_us: age_twenty_and_us,
        age_over_fifty: age_over_fifty,
        age_twenty_and_us_or_over_fifty: age_twenty_and_us_or_over_fifty,
        returning: returning,
        returning_and_combo: returning_and_age_twenty_and_us_or_over_fifty,
        not_returning_and_spanish: not_returning_and_spanish
      }
    end

    test "AgeTwentyAndUS", %{john: john, terry: terry, kate: kate, maria: maria, age_twenty_and_us: expr} do
      assert evaluate_boolean(expr, john) == true
      assert evaluate_boolean(expr, terry) == false
      assert evaluate_boolean(expr, kate) == false
      assert evaluate_boolean(expr, maria) == false
    end

    test "AgeOverFifty", %{john: john, terry: terry, kate: kate, maria: maria, age_over_fifty: expr} do
      assert evaluate_boolean(expr, john) == false
      assert evaluate_boolean(expr, terry) == false
      assert evaluate_boolean(expr, kate) == true
      assert evaluate_boolean(expr, maria) == true
    end

    test "AgeTwentyAndUS_Or_AgeOverFifty", %{john: john, terry: terry, kate: kate, maria: maria, age_twenty_and_us_or_over_fifty: expr} do
      assert evaluate_boolean(expr, john) == true
      assert evaluate_boolean(expr, terry) == false
      assert evaluate_boolean(expr, kate) == true
      assert evaluate_boolean(expr, maria) == true
    end

    test "Returning", %{john: john, terry: terry, kate: kate, maria: maria, returning: expr} do
      assert evaluate_boolean(expr, john) == false
      assert evaluate_boolean(expr, terry) == true
      assert evaluate_boolean(expr, kate) == false
      assert evaluate_boolean(expr, maria) == true
    end

    test "Returning_And_AgeTwentyAndUS_Or_AgeOverFifty", %{john: john, terry: terry, kate: kate, maria: maria, returning_and_combo: expr} do
      assert evaluate_boolean(expr, john) == false
      assert evaluate_boolean(expr, terry) == false
      assert evaluate_boolean(expr, kate) == false
      assert evaluate_boolean(expr, maria) == true
    end

    test "NotReturning_And_Spanish", %{john: john, terry: terry, kate: kate, maria: maria, not_returning_and_spanish: expr} do
      assert evaluate_boolean(expr, john) == false
      assert evaluate_boolean(expr, terry) == false
      assert evaluate_boolean(expr, kate) == true
      assert evaluate_boolean(expr, maria) == false
    end
  end

  defp evaluate_boolean(exprs, vars) when is_list(exprs) do
    result = Evaluator.evaluate(%{"and" => exprs}, vars)
    result == true
  end
end
