defmodule ABSmartly.SharedVariableKeyTest do
  @moduledoc """
  Several experiments defining the same variable key. Mirrors the Java SDK's
  `Context.getVariableAssignment`: the candidates are the experiments whose
  variants define the key, by experiment id ascending; the winner is the first
  one the unit is assigned to, overridden into or given by a rule (else the
  first held-out one, for its control value); the value is the winner's
  variant's value for the key, or the default when that variant lacks it. Only
  the winner is exposed, and `peek_variable_value/3` exposes nothing.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types}
  alias ABSmartly.Test.ScriptedPublisher

  @unit_type "session_id"
  @uid "e791e240fcd3df7d238cfc285f475e8152fcc0ec"

  @us_audience ~s({"filter":[{"eq":[{"var":"country"},{"value":"US"}]}]})
  @us_rule ~s({"rules":[{"name":"US","type":"assign","conditions":{"and":[{"eq":[{"var":"country"},{"value":"US"}]}]},"environments":[],"variant":1}]})

  # Every experiment assigns variant 1 to a unit it has (split [0, 1]).
  defp experiment(id, name, configs, opts \\ []) do
    %{
      "id" => id,
      "name" => name,
      "iteration" => 1,
      "unitType" => Keyword.get(opts, :unit_type, @unit_type),
      "seedHi" => 100,
      "seedLo" => 200,
      "split" => Keyword.get(opts, :split, [0.0, 1.0]),
      "trafficSeedHi" => 1,
      "trafficSeedLo" => 2,
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => 0,
      "applications" => [%{"name" => "website"}],
      "variants" =>
        configs
        |> Enum.with_index()
        |> Enum.map(fn {config, i} ->
          %{"name" => "v#{i}", "config" => config && Jason.encode!(config)}
        end),
      "audienceStrict" => Keyword.get(opts, :audience_strict, false),
      "audience" => Keyword.get(opts, :audience),
      "assignmentRules" => Keyword.get(opts, :rules)
    }
  end

  defp start(experiments, opts \\ []) do
    endpoint = ScriptedPublisher.start([])

    sdk_config = %Types.SDKConfig{
      endpoint: endpoint,
      api_key: "test-api-key",
      application: "website",
      environment: "production",
      publisher: ScriptedPublisher
    }

    context_config = %Types.ContextConfig{
      units: Keyword.get(opts, :units, %{@unit_type => @uid}),
      overrides: Keyword.get(opts, :overrides, %{})
    }

    data = Types.ContextData.from_map(%{"experiments" => experiments})
    {:ok, ctx} = Context.start_link(sdk_config, data, context_config)

    for {name, value} <- Keyword.get(opts, :attributes, []),
        do: :ok = Context.set_attribute(ctx, name, value)

    {ctx, endpoint}
  end

  defp exposed(ctx, endpoint) do
    :ok = Context.publish(ctx)

    endpoint
    |> ScriptedPublisher.attempts()
    |> Enum.flat_map(&(&1["exposures"] || []))
    |> Enum.map(&{&1["id"], &1["name"]})
  end

  defp strict_us(id, name, configs),
    do: experiment(id, name, configs, audience: @us_audience, audience_strict: true)

  describe "the winner is the first candidate the unit is in" do
    test "a strict audience mismatch on the lower id loses to the higher id" do
      {ctx, ep} =
        start(
          [
            strict_us(1, "exp_low", [%{"k" => "low0"}, %{"k" => "low1"}]),
            experiment(2, "exp_high", [%{"k" => "high0"}, %{"k" => "high1"}])
          ],
          attributes: [country: "GB"]
        )

      assert Context.variable_value(ctx, "k", "default") == "high1"
      assert Context.pending(ctx) == 1
      assert exposed(ctx, ep) == [{2, "exp_high"}]
    end

    test "a lower id for a unit type the context lacks loses to the higher id" do
      {ctx, ep} =
        start([
          experiment(1, "exp_low", [%{"k" => "low0"}, %{"k" => "low1"}], unit_type: "user_id"),
          experiment(2, "exp_high", [%{"k" => "high0"}, %{"k" => "high1"}])
        ])

      assert Context.variable_value(ctx, "k", "default") == "high1"
      assert Context.pending(ctx) == 1
      assert exposed(ctx, ep) == [{2, "exp_high"}]
    end

    test "candidates are ordered by experiment id, not by the order in the data" do
      {ctx, ep} =
        start([
          experiment(7, "exp_seven", [%{"k" => "seven0"}, %{"k" => "seven1"}]),
          experiment(3, "exp_three", [%{"k" => "three0"}, %{"k" => "three1"}])
        ])

      assert Context.variable_keys(ctx) == %{"k" => ["exp_three", "exp_seven"]}
      assert Context.peek_variable_value(ctx, "k", "default") == "three1"
      assert Context.variable_value(ctx, "k", "default") == "three1"
      assert exposed(ctx, ep) == [{3, "exp_three"}]
    end

    test "a key defined only by a variant the unit did not get still makes a candidate" do
      {ctx, ep} =
        start([
          experiment(1, "exp_low", [%{"k" => "low0"}, %{"other" => 1}]),
          experiment(2, "exp_high", [%{"k" => "high0"}, %{"k" => "high1"}])
        ])

      assert Context.variable_value(ctx, "k", "default") == "default"
      assert exposed(ctx, ep) == [{1, "exp_low"}]
    end
  end

  describe "the winner's variant lacks the key" do
    test "returns the default and exposes only the winner" do
      {ctx, ep} =
        start([
          experiment(1, "exp_winner", [%{"k" => "w0"}, nil]),
          experiment(2, "exp_later", [%{"k" => "l0"}, %{"k" => "l1"}])
        ])

      assert Context.variable_value(ctx, "k", "default") == "default"
      assert Context.pending(ctx) == 1
      assert exposed(ctx, ep) == [{1, "exp_winner"}]
    end

    test "peek returns the default too and exposes nothing" do
      {ctx, _} =
        start([
          experiment(1, "exp_winner", [%{"k" => "w0"}, %{}]),
          experiment(2, "exp_later", [%{"k" => "l0"}, %{"k" => "l1"}])
        ])

      assert Context.peek_variable_value(ctx, "k", "default") == "default"
      assert Context.pending(ctx) == 0
    end
  end

  describe "no candidate the unit is in" do
    test "returns the default and exposes nothing" do
      {ctx, ep} =
        start(
          [
            strict_us(1, "exp_a", [%{"k" => "a0"}, %{"k" => "a1"}]),
            experiment(2, "exp_b", [%{"k" => "b0"}, %{"k" => "b1"}], unit_type: "user_id")
          ],
          attributes: [country: "GB"]
        )

      assert Context.variable_value(ctx, "k", "default") == "default"
      assert Context.pending(ctx) == 0
      assert exposed(ctx, ep) == []
    end
  end

  describe "peek_variable_value" do
    test "returns the winner's value and exposes nothing" do
      {ctx, _} =
        start(
          [
            strict_us(1, "exp_low", [%{"k" => "low0"}, %{"k" => "low1"}]),
            experiment(2, "exp_high", [%{"k" => "high0"}, %{"k" => "high1"}])
          ],
          attributes: [country: "GB"]
        )

      assert Context.peek_variable_value(ctx, "k", "default") == "high1"
      assert Context.pending(ctx) == 0
    end
  end

  describe "overrides and assignment rules" do
    test "an override on an otherwise unassigned lower id wins" do
      {ctx, ep} =
        start(
          [
            strict_us(1, "exp_low", [%{"k" => "low0"}, %{"k" => "low1"}]),
            experiment(2, "exp_high", [%{"k" => "high0"}, %{"k" => "high1"}])
          ],
          attributes: [country: "GB"],
          overrides: %{"exp_low" => 0}
        )

      assert Context.variable_value(ctx, "k", "default") == "low0"
      assert exposed(ctx, ep) == [{1, "exp_low"}]
    end

    test "an override to a variant lacking the key returns the default" do
      {ctx, ep} =
        start(
          [
            experiment(1, "exp_low", [%{"k" => "low0"}, %{"k" => "low1"}, %{}]),
            experiment(2, "exp_high", [%{"k" => "high0"}, %{"k" => "high1"}])
          ],
          overrides: %{"exp_low" => 2}
        )

      assert Context.variable_value(ctx, "k", "default") == "default"
      assert exposed(ctx, ep) == [{1, "exp_low"}]
    end

    test "a rule-assigned lower id wins over an assigned higher id" do
      {ctx, ep} =
        start(
          [
            experiment(1, "exp_rule", [%{"k" => "rule0"}, %{"k" => "rule1"}],
              audience: ~s({"filter":[{"value":false}]}),
              audience_strict: true,
              rules: @us_rule
            ),
            experiment(2, "exp_high", [%{"k" => "high0"}, %{"k" => "high1"}])
          ],
          attributes: [country: "US"]
        )

      assert Context.variable_value(ctx, "k", "default") == "rule1"
      assert exposed(ctx, ep) == [{1, "exp_rule"}]
    end

    test "an assigned lower id wins over a rule-assigned higher id" do
      {ctx, ep} =
        start(
          [
            experiment(1, "exp_low", [%{"k" => "low0"}, %{"k" => "low1"}], split: [1.0, 0.0]),
            experiment(2, "exp_rule", [%{"k" => "rule0"}, %{"k" => "rule1"}], rules: @us_rule)
          ],
          attributes: [country: "US"]
        )

      assert Context.variable_value(ctx, "k", "default") == "low0"
      assert exposed(ctx, ep) == [{1, "exp_low"}]
    end
  end

  describe "falsy values are values, a missing key is not" do
    for {label, value} <- [null: nil, false: false, zero: 0, empty_string: "", empty_map: %{}] do
      test "a #{label} value is returned and does not fall through" do
        {ctx, ep} =
          start([
            experiment(1, "exp_low", [%{"k" => "low0"}, %{"k" => unquote(Macro.escape(value))}]),
            experiment(2, "exp_high", [%{"k" => "high0"}, %{"k" => "high1"}])
          ])

        assert Context.peek_variable_value(ctx, "k", "default") == unquote(Macro.escape(value))
        assert Context.variable_value(ctx, "k", "default") == unquote(Macro.escape(value))
        assert exposed(ctx, ep) == [{1, "exp_low"}]
      end
    end
  end

  test "of two experiments with the same id only the first in the data is a candidate" do
    {ctx, ep} =
      start([
        experiment(5, "exp_dup_a", [%{"k" => "a0"}, %{"other" => 1}]),
        experiment(5, "exp_dup_b", [%{"k" => "b0"}, %{"k" => "b1"}])
      ])

    assert Context.variable_keys(ctx)["k"] == ["exp_dup_a"]
    assert Context.variable_value(ctx, "k", "default") == "default"
    assert exposed(ctx, ep) == [{5, "exp_dup_a"}]
  end

  test "an integral float id is the same id as the integer" do
    {ctx, ep} =
      start(
        [
          strict_us(5, "exp_int", [%{"k" => "int0"}, %{"k" => "int1"}]),
          experiment(5.0, "exp_float", [%{"k" => "float0"}, %{"k" => "float1"}])
        ],
        attributes: [country: "GB"]
      )

    assert Context.variable_keys(ctx)["k"] == ["exp_int"]
    assert Context.variable_value(ctx, "k", "default") == "default"
    assert exposed(ctx, ep) == []
  end

  test "a non-integral float id is ordered and deduplicated as its integer part" do
    {ctx, ep} =
      start([
        experiment(3.5, "exp_float", [%{"k" => "float0"}, %{"k" => "float1"}]),
        experiment(3, "exp_int", [%{"k" => "int0"}, %{"k" => "int1"}]),
        experiment(2.9, "exp_low", [%{"k" => "low0"}, %{"k" => "low1"}])
      ])

    assert Context.variable_keys(ctx)["k"] == ["exp_low", "exp_float"]
    assert Context.variable_value(ctx, "k", "default") == "low1"
    assert exposed(ctx, ep) == [{2.9, "exp_low"}]
  end

  test "a negative non-integral float id is truncated towards zero" do
    {ctx, _ep} =
      start([
        experiment(-5, "exp_int", [%{"k" => "int0"}, %{"k" => "int1"}]),
        experiment(-5.7, "exp_float", [%{"k" => "float0"}, %{"k" => "float1"}])
      ])

    assert Context.variable_keys(ctx)["k"] == ["exp_int"]
  end

  test "a numeric string id is ordered as its integer" do
    {ctx, ep} =
      start([
        experiment(7, "exp_a", [%{"k" => "a0"}, %{"k" => "a1"}]),
        experiment("3", "exp_b", [%{"k" => "b0"}, %{"k" => "b1"}])
      ])

    assert Context.variable_keys(ctx)["k"] == ["exp_b", "exp_a"]
    assert Context.variable_value(ctx, "k", "default") == "b1"
    assert exposed(ctx, ep) == [{"3", "exp_b"}]
  end

  test "a padded numeric string id is its integer and an empty one is 0" do
    {ctx, _ep} =
      start([
        experiment(3, "exp_a", [%{"k" => "a0"}, %{"k" => "a1"}]),
        experiment(" 2", "exp_b", [%{"k" => "b0"}, %{"k" => "b1"}]),
        experiment("", "exp_c", [%{"k" => "c0"}, %{"k" => "c1"}])
      ])

    assert Context.variable_keys(ctx)["k"] == ["exp_c", "exp_b", "exp_a"]
  end

  test "a non-numeric id sorts after every numeric id" do
    {ctx, _ep} =
      start([
        experiment("x", "exp_x", [%{"k" => "x0"}, %{"k" => "x1"}]),
        experiment(900, "exp_n", [%{"k" => "n0"}, %{"k" => "n1"}])
      ])

    assert Context.variable_keys(ctx)["k"] == ["exp_n", "exp_x"]
  end

  test "a late unit assignment re-evaluates an unexposed missing-unit candidate" do
    {ctx, ep} =
      start(
        [
          experiment(2, "exp_session", [%{"k" => "session0"}, %{"k" => "session1"}]),
          experiment(1, "exp_user", [%{"k" => "user0"}, %{"k" => "user1"}], unit_type: "user_id")
        ],
        units: %{"session_id" => @uid}
      )

    assert Context.variable_value(ctx, "k", "default") == "session1"
    assert :ok = Context.set_unit(ctx, "user_id", "user-1")
    assert Context.treatment(ctx, "exp_user") == 1
    assert exposed(ctx, ep) == [{2, "exp_session"}, {1, "exp_user"}]
  end

  test "a later read of another key exposes its own winner once" do
    {ctx, ep} =
      start([
        experiment(1, "exp_a", [%{"k" => "a0"}, %{"k" => "a1", "j" => "aj"}]),
        experiment(2, "exp_b", [%{"k" => "b0", "j" => "bj0"}, %{"k" => "b1", "j" => "bj1"}])
      ])

    assert Context.variable_value(ctx, "k", "default") == "a1"
    assert Context.variable_value(ctx, "k", "default") == "a1"
    assert Context.variable_value(ctx, "j", "default") == "aj"
    assert exposed(ctx, ep) == [{1, "exp_a"}]
  end
end
