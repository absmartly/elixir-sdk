defmodule ABSmartly.SemverTest do
  use ExUnit.Case, async: true

  alias ABSmartly.JSONExpr.Evaluator
  alias ABSmartly.Semver

  doctest ABSmartly.Semver

  # Same vectors as the Java SDK's SemverComparatorTest (java-sdk#17), which
  # mirrors the JavaScript SDK's `versionCompare`.
  @cases [
    {"1.0.0", "1.0.0", 0},
    {"0.0.0", "0.0.0", 0},
    {"999.999.999", "999.999.999", 0},
    {"2.0.0", "1.0.0", 1},
    {"1.0.0", "2.0.0", -1},
    {"1.2.0", "1.1.0", 1},
    {"1.1.0", "1.2.0", -1},
    {"1.0.2", "1.0.1", 1},
    {"1.0.1", "1.0.2", -1},
    {"1.10.0", "1.9.0", 1},
    {"1.9.0", "1.10.0", -1},
    {"10.0.0", "9.0.0", 1},
    {"1.2", "1.2.0", 0},
    {"1", "1.0.0", 0},
    {"1.2.0", "1.2", 0},
    {"1.0.0", "1", 0},
    {"1.02.0", "1.2.0", 0},
    {"1.002.030", "1.2.30", 0},
    {"01.0.0", "1.0.0", 0},
    {"1.02.0", "1.3.0", -1},
    {"1.00.0", "1.0.0", 0},
    {"1.0.0", "1.0.0-alpha", 1},
    {"1.0.0-alpha", "1.0.0", -1},
    {"1.0.0-alpha", "1.0.0-alpha", 0},
    {"1.0.0-alpha", "1.0.0-beta", -1},
    {"1.0.0-beta", "1.0.0-alpha", 1},
    {"1.0.0-alpha.1", "1.0.0-alpha.2", -1},
    {"1.0.0-alpha.2", "1.0.0-alpha.1", 1},
    {"1.0.0-1", "1.0.0-2", -1},
    {"1.0.0-2", "1.0.0-1", 1},
    {"1.0.0-alpha.10", "1.0.0-alpha.9", 1},
    {"1.0.0-rc-1", "1.0.0-rc-1", 0},
    {"1.0.0-1", "1.0.0-alpha", -1},
    {"1.0.0-alpha", "1.0.0-1", 1},
    {"1.0.0-alpha", "1.0.0-alpha.1", -1},
    {"1.0.0-alpha.1", "1.0.0-alpha", 1},
    {"v1.0.0", "1.0.0", 0},
    {"V1.0.0", "1.0.0", 0},
    {"v1.0.0", "V1.0.0", 0},
    {"1.0.0+build1", "1.0.0+build2", 0},
    {"1.0.0+build1", "1.0.0", 0},
    {"1.0.0-alpha+build1", "1.0.0-alpha+build2", 0},
    {"1.0.0-alpha+build1", "1.0.0-beta", -1},
    {"1.0.0-alpha+build1", "1.0.0", -1},
    {"12345678901234567890.0.0", "9.0.0", 1}
  ]

  describe "compare/2" do
    test "orders versions like the JavaScript and Java SDKs" do
      for {lhs, rhs, expected} <- @cases do
        assert Semver.compare(lhs, rhs) == expected, "#{lhs} vs #{rhs}"
      end
    end

    test "gives nil for empty or non-version input" do
      for {lhs, rhs} <- [
            {"", "1.0.0"},
            {"1.0.0", ""},
            {"", ""},
            {"v", "1.0.0"},
            {"V", "1.0.0"},
            {"+build", "1.0.0"},
            {"v+build", "1.0.0"},
            {"1.0.0", "v"},
            {"-alpha", "1.0.0"},
            {nil, "1.0.0"},
            {"1.0.0", nil},
            {1, "1.0.0"}
          ] do
        assert Semver.compare(lhs, rhs) == nil, "#{inspect(lhs)} vs #{inspect(rhs)}"
      end
    end
  end

  describe "semver operators" do
    defp eval(op, lhs, rhs),
      do: Evaluator.evaluate(%{op => [%{"value" => lhs}, %{"value" => rhs}]}, %{})

    test "each operator applies its comparison" do
      assert eval("semver_eq", "v1.2", "1.2.0+build") == true
      assert eval("semver_eq", "1.2.1", "1.2.0") == false
      assert eval("semver_gt", "1.10.0", "1.9.0") == true
      assert eval("semver_gt", "1.9.0", "1.9.0") == false
      assert eval("semver_gte", "1.5.0", "1.2.0") == true
      assert eval("semver_gte", "1.2.0", "1.2.0") == true
      assert eval("semver_gte", "1.1.0", "1.2.0") == false
      assert eval("semver_lt", "1.0.0-beta", "1.0.0") == true
      assert eval("semver_lt", "1.0.0", "1.0.0") == false
      assert eval("semver_lte", "2.0.0", "2.0.0") == true
      assert eval("semver_lte", "2.0.1", "2.0.0") == false
    end

    test "operands are converted to strings first" do
      assert eval("semver_eq", 1, "1.0.0") == true
      assert eval("semver_eq", "1.0.0", 1) == true
      assert eval("semver_eq", 2.5, "2.5.0") == true
      assert eval("semver_eq", true, "true") == true
    end

    test "give nil for a nil, empty or non-convertible operand" do
      for op <- ~w(semver_eq semver_gt semver_gte semver_lt semver_lte) do
        assert eval(op, nil, "1.0.0") == nil
        assert eval(op, "1.0.0", nil) == nil
        assert eval(op, "", "1.0.0") == nil
        assert eval(op, %{}, "1.0.0") == nil
        assert eval(op, "1.0.0", [1]) == nil
      end
    end

    test "compare an attribute in an audience filter" do
      filter = %{"semver_gte" => [%{"var" => "app_version"}, %{"value" => "2.4.0"}]}

      assert Evaluator.evaluate(filter, %{"app_version" => "2.10.0"}) == true
      assert Evaluator.evaluate(filter, %{"app_version" => "2.3.99"}) == false
      assert Evaluator.evaluate(filter, %{}) == nil
    end
  end
end
