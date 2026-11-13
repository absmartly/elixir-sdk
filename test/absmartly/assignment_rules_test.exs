defmodule ABSmartly.AssignmentRulesTest do
  @moduledoc """
  Custom assignment rules: an experiment's `assignmentRules` are evaluated in
  order and the first matching rule wins over audience targeting, traffic
  allocation and custom assignments. Only an override beats a rule.

  Mirrors the JavaScript SDK (javascript-sdk#66, #67) and the Java SDK
  (java-sdk#17) context tests.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types, Utils, VariantAssigner}

  @session "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
  @us %{"eq" => [%{"var" => "country"}, %{"value" => "US"}]}

  defmodule CapturePublisher do
    @moduledoc false
    @behaviour ABSmartly.ContextPublisher

    def start do
      name = :"rules_capture_publisher_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Agent.start_link(fn -> [] end, name: name)
      Atom.to_string(name)
    end

    def exposures(endpoint) do
      endpoint
      |> String.to_existing_atom()
      |> Agent.get(&Enum.reverse/1)
      |> Enum.flat_map(&(&1["exposures"] || []))
    end

    @impl ABSmartly.ContextPublisher
    def publish(endpoint, _api_key, _application, _environment, event_map, _retries) do
      Agent.update(String.to_existing_atom(endpoint), &[event_map | &1])
      :ok
    end
  end

  defp assign(name, conditions, variant, environments \\ []) do
    %{
      "name" => name,
      "type" => "assign",
      "conditions" => conditions,
      "environments" => environments,
      "variant" => variant
    }
  end

  defp split(name, conditions, percentages) do
    %{
      "name" => name,
      "type" => "split",
      "conditions" => conditions,
      "environments" => [],
      "percentages" => percentages
    }
  end

  defp rules(rules), do: Jason.encode!(%{"rules" => rules})

  # Three variants, a 1/3 split and no traffic exclusion, so the normal
  # (rule-less) assignment is a deterministic function of the unit.
  defp experiment(assignment_rules, opts \\ []) do
    %{
      "id" => 2,
      "name" => "exp_test_abc",
      "iteration" => 1,
      "unitType" => "session_id",
      "seedHi" => 55_006_150,
      "seedLo" => 47_189_152,
      "split" => [0.34, 0.33, 0.33],
      "trafficSeedHi" => 705_671_872,
      "trafficSeedLo" => 212_903_484,
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => Keyword.get(opts, :full_on_variant, 0),
      "applications" => [%{"name" => "website"}],
      "variants" => [
        %{"name" => "A", "config" => nil},
        %{"name" => "B", "config" => "{\"button.color\":\"blue\"}"},
        %{"name" => "C", "config" => "{\"button.color\":\"red\"}"}
      ],
      "audience" => Keyword.get(opts, :audience),
      "audienceStrict" => Keyword.get(opts, :audience_strict, false),
      "customFieldValues" => nil,
      "assignmentRules" => assignment_rules
    }
  end

  defp start_context(experiment, opts \\ []) do
    endpoint = Keyword.get_lazy(opts, :endpoint, &CapturePublisher.start/0)

    sdk_config = %Types.SDKConfig{
      endpoint: endpoint,
      api_key: "test-api-key",
      application: "website",
      environment: Keyword.get(opts, :environment, "production"),
      publisher: CapturePublisher
    }

    context_config = %Types.ContextConfig{
      units: Keyword.get(opts, :units, %{"session_id" => @session}),
      attributes: Keyword.get(opts, :attributes, []),
      overrides: Keyword.get(opts, :overrides, %{}),
      custom_assignments: Keyword.get(opts, :custom_assignments, %{})
    }

    data = Types.ContextData.from_map(%{"experiments" => List.wrap(experiment)})
    {:ok, ctx} = Context.start_link(sdk_config, data, context_config)
    {ctx, endpoint}
  end

  defp published_exposures(ctx, endpoint) do
    :ok = Context.publish(ctx)
    CapturePublisher.exposures(endpoint)
  end

  defp normal_variant(split \\ [0.34, 0.33, 0.33]) do
    VariantAssigner.assign(Utils.hash_unit(@session), split, 55_006_150, 47_189_152)
  end

  describe "assign rules" do
    test "a matching rule assigns its variant" do
      {ctx, _} = start_context(experiment(rules([assign("US", @us, 1)])))
      :ok = Context.set_attribute(ctx, "country", "US")

      assert Context.treatment(ctx, "exp_test_abc") == 1
    end

    test "a non-matching rule falls through to normal assignment" do
      {ctx, _} = start_context(experiment(rules([assign("US", @us, 1)])))
      :ok = Context.set_attribute(ctx, "country", "GB")

      assert Context.treatment(ctx, "exp_test_abc") == normal_variant()
    end

    test "the first matching rule wins" do
      {ctx, _} = start_context(experiment(rules([assign("US", @us, 2), assign("All", nil, 1)])))
      :ok = Context.set_attribute(ctx, "country", "US")

      assert Context.treatment(ctx, "exp_test_abc") == 2
    end

    test "the exposure is flagged ruleOverride and not assigned" do
      {ctx, endpoint} = start_context(experiment(rules([assign("US", @us, 1)])))
      :ok = Context.set_attribute(ctx, "country", "US")
      Context.treatment(ctx, "exp_test_abc")

      assert [exposure] = published_exposures(ctx, endpoint)

      assert Map.drop(exposure, ["exposedAt"]) == %{
               "id" => 2,
               "name" => "exp_test_abc",
               "unit" => "session_id",
               "variant" => 1,
               "assigned" => false,
               "eligible" => true,
               "overridden" => false,
               "fullOn" => false,
               "custom" => false,
               "audienceMismatch" => false,
               "ruleOverride" => true
             }
    end

    test "a normal assignment is published with ruleOverride false" do
      {ctx, endpoint} = start_context(experiment(nil))
      Context.treatment(ctx, "exp_test_abc")

      assert [%{"ruleOverride" => false, "assigned" => true}] =
               published_exposures(ctx, endpoint)
    end

    test "an out-of-range variant is ignored and later rules are not tried" do
      for variant <- [3, -1] do
        {ctx, _} =
          start_context(experiment(rules([assign("bad", nil, variant), assign("All", nil, 1)])))

        assert Context.treatment(ctx, "exp_test_abc") == normal_variant()
      end
    end

    test "rules with an invalid action are skipped" do
      bad = [
        %{"type" => "assign", "variant" => 1.5},
        %{"type" => "assign", "variant" => "1"},
        %{"type" => "unknown", "variant" => 1},
        %{"variant" => 1},
        nil
      ]

      {ctx, _} = start_context(experiment(rules(bad ++ [assign("All", nil, 1)])))
      assert Context.treatment(ctx, "exp_test_abc") == 1
    end

    test "an environment-scoped rule only matches its environments" do
      exp = experiment(rules([assign("prod", nil, 1, ["production"])]))

      {prod, _} = start_context(exp, environment: "production")
      assert Context.treatment(prod, "exp_test_abc") == 1

      {staging, _} = start_context(exp, environment: "staging")
      assert Context.treatment(staging, "exp_test_abc") == normal_variant()

      {none, _} = start_context(exp, environment: nil)
      assert Context.treatment(none, "exp_test_abc") == normal_variant()
    end

    test "an empty environments list matches every environment, even none" do
      exp = experiment(rules([assign("all", nil, 1, [])]))

      for environment <- ["production", "staging", nil] do
        {ctx, _} = start_context(exp, environment: environment)
        assert Context.treatment(ctx, "exp_test_abc") == 1
      end
    end

    test "a rule whose environments is not a list is skipped" do
      bad = %{"type" => "assign", "environments" => "production", "variant" => 0}
      {ctx, _} = start_context(experiment(rules([bad, assign("All", nil, 1)])))

      assert Context.treatment(ctx, "exp_test_abc") == 1
    end

    test "a rule whose conditions are not an object is skipped" do
      bad = %{"type" => "assign", "conditions" => "yes", "variant" => 0}
      {ctx, _} = start_context(experiment(rules([bad, assign("All", nil, 1)])))

      assert Context.treatment(ctx, "exp_test_abc") == 1
    end

    test "a rule without conditions matches everyone" do
      rule = %{"type" => "assign", "variant" => 0}
      {ctx, _} = start_context(experiment(rules([rule])))

      assert Context.treatment(ctx, "exp_test_abc") == 0
    end

    test "invalid assignmentRules are ignored for that experiment only" do
      for value <- ["not json", "[]", "{\"rules\":{}}", "", %{"rules" => []}, 42] do
        {ctx, _} = start_context(experiment(value))
        assert Context.treatment(ctx, "exp_test_abc") == normal_variant()
      end
    end

    test "an override beats a matching rule" do
      {ctx, _} =
        start_context(experiment(rules([assign("All", nil, 1)])),
          overrides: %{"exp_test_abc" => 2}
        )

      assert Context.treatment(ctx, "exp_test_abc") == 2
    end

    test "a rule wins over a strict audience mismatch" do
      audience =
        Jason.encode!(%{"filter" => [%{"eq" => [%{"var" => "tier"}, %{"value" => "gold"}]}]})

      {ctx, endpoint} =
        start_context(
          experiment(rules([assign("All", nil, 1)]), audience: audience, audience_strict: true)
        )

      assert Context.treatment(ctx, "exp_test_abc") == 1

      assert [%{"audienceMismatch" => false, "ruleOverride" => true}] =
               published_exposures(ctx, endpoint)
    end

    test "a rule wins over a full-on variant" do
      {ctx, _} = start_context(experiment(rules([assign("All", nil, 1)]), full_on_variant: 2))
      assert Context.treatment(ctx, "exp_test_abc") == 1
    end

    test "a rule needs no unit" do
      {ctx, endpoint} = start_context(experiment(rules([assign("All", nil, 2)])), units: %{})
      assert Context.treatment(ctx, "exp_test_abc") == 2

      assert [%{"variant" => 2, "ruleOverride" => true}] = published_exposures(ctx, endpoint)
    end

    test "a rule wins over a custom assignment" do
      {ctx, endpoint} =
        start_context(experiment(rules([assign("US", @us, 1)])),
          custom_assignments: %{"exp_test_abc" => 2}
        )

      :ok = Context.set_attribute(ctx, "country", "US")
      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.treatment(ctx, "exp_test_abc") == 1

      assert [%{"variant" => 1, "custom" => false, "ruleOverride" => true}] =
               published_exposures(ctx, endpoint)
    end

    test "a rule that wins over a custom assignment is exposed only once, then gives way" do
      {ctx, _} = start_context(experiment(rules([assign("US", @us, 1)])))
      :ok = Context.set_attribute(ctx, "country", "US")
      :ok = Context.set_custom_assignment(ctx, "exp_test_abc", 0)

      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.pending(ctx) == 1

      :ok = Context.set_attribute(ctx, "country", "GB")
      assert Context.treatment(ctx, "exp_test_abc") == 0
    end

    test "variable values are served through a rule win" do
      {ctx, _} = start_context(experiment(rules([assign("All", nil, 1)])))

      assert Context.variable_value(ctx, "button.color", "default") == "blue"
      assert Context.pending(ctx) == 1
    end

    test "rule conditions see the configured application and environment" do
      app = %{"eq" => [%{"var" => "application"}, %{"value" => "website"}]}
      env = %{"eq" => [%{"var" => "environment"}, %{"value" => "production"}]}

      {ctx, _} = start_context(experiment(rules([assign("app", app, 1)])))
      assert Context.treatment(ctx, "exp_test_abc") == 1

      {ctx, _} = start_context(experiment(rules([assign("env", env, 0)])))
      assert Context.treatment(ctx, "exp_test_abc") == 0

      {ctx, _} = start_context(experiment(rules([assign("env", env, 0)])), environment: "staging")
      assert Context.treatment(ctx, "exp_test_abc") == normal_variant()
    end

    test "a user-set environment wins over the configured one in rule conditions" do
      env = %{"eq" => [%{"var" => "environment"}, %{"value" => "staging"}]}

      {ctx, _} = start_context(experiment(rules([assign("env", env, 1)])))
      assert Context.peek(ctx, "exp_test_abc") == normal_variant()

      :ok = Context.set_attribute(ctx, "environment", "staging")
      assert Context.peek(ctx, "exp_test_abc") == 1
    end

    test "rule conditions can use semver operators" do
      condition = %{"semver_gte" => [%{"var" => "app_version"}, %{"value" => "2.4.0"}]}
      {ctx, _} = start_context(experiment(rules([assign("new", condition, 1)])))

      :ok = Context.set_attribute(ctx, "app_version", "2.3.9")
      assert Context.peek(ctx, "exp_test_abc") == normal_variant()

      :ok = Context.set_attribute(ctx, "app_version", "v2.10.0")
      assert Context.peek(ctx, "exp_test_abc") == 1
    end
  end

  describe "re-evaluation" do
    test "a rule that starts matching after an attribute change reassigns and re-exposes" do
      {ctx, endpoint} = start_context(experiment(rules([assign("US", @us, 1)])))
      :ok = Context.set_attribute(ctx, "country", "GB")
      assert Context.treatment(ctx, "exp_test_abc") == normal_variant()

      :ok = Context.set_attribute(ctx, "country", "US")
      assert Context.treatment(ctx, "exp_test_abc") == 1

      assert [%{"ruleOverride" => false}, %{"variant" => 1, "ruleOverride" => true}] =
               published_exposures(ctx, endpoint)
    end

    test "an unrelated attribute change keeps the exposure" do
      {ctx, _} = start_context(experiment(rules([assign("US", @us, 1)])))
      :ok = Context.set_attribute(ctx, "country", "US")
      assert Context.treatment(ctx, "exp_test_abc") == 1

      :ok = Context.set_attribute(ctx, "unrelated", true)
      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.pending(ctx) == 1
    end

    test "a rule win ignores audience changes" do
      audience =
        Jason.encode!(%{"filter" => [%{"eq" => [%{"var" => "tier"}, %{"value" => "gold"}]}]})

      {ctx, _} =
        start_context(
          experiment(rules([assign("All", nil, 1)]), audience: audience, audience_strict: true)
        )

      assert Context.treatment(ctx, "exp_test_abc") == 1
      :ok = Context.set_attribute(ctx, "tier", "silver")
      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.pending(ctx) == 1
    end

    test "a refresh that changes the rules re-resolves the assignment" do
      {ctx, _} = start_context(experiment(rules([assign("All", nil, 1)])))
      assert Context.treatment(ctx, "exp_test_abc") == 1

      :ok =
        Context.refresh(ctx, %{"experiments" => [experiment(rules([assign("All", nil, 0)]))]})

      assert Context.treatment(ctx, "exp_test_abc") == 0
      assert Context.pending(ctx) == 2
    end

    test "a refresh that keeps the same rule outcome keeps the exposure" do
      {ctx, _} = start_context(experiment(rules([assign("All", nil, 1)])))
      assert Context.treatment(ctx, "exp_test_abc") == 1

      :ok =
        Context.refresh(ctx, %{
          "experiments" => [experiment(rules([assign("Renamed", nil, 1)]))]
        })

      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.pending(ctx) == 1
    end

    test "a refresh that removes the rules drops the rule variant" do
      {ctx, _} = start_context(experiment(rules([assign("All", nil, 1)])))
      assert Context.treatment(ctx, "exp_test_abc") == 1

      :ok = Context.refresh(ctx, %{"experiments" => [experiment(nil)]})

      assert Context.treatment(ctx, "exp_test_abc") == normal_variant()
      assert Context.pending(ctx) == 2
    end

    test "a refresh that empties the rules drops the rule variant" do
      for rules <- ["", nil] do
        {ctx, _} = start_context(experiment(rules([assign("All", nil, 1)])))
        assert Context.treatment(ctx, "exp_test_abc") == 1

        :ok = Context.refresh(ctx, %{"experiments" => [experiment(rules)]})
        assert Context.treatment(ctx, "exp_test_abc") == normal_variant(), inspect(rules)
      end
    end

    test "a refresh whose rules no longer parse drops the rule variant" do
      for rules <- ["not json", "{\"rules\":{}}"] do
        {ctx, _} = start_context(experiment(rules([assign("All", nil, 1)])))
        assert Context.treatment(ctx, "exp_test_abc") == 1

        :ok = Context.refresh(ctx, %{"experiments" => [experiment(rules)]})
        assert Context.treatment(ctx, "exp_test_abc") == normal_variant(), inspect(rules)
        assert Context.pending(ctx) == 2
      end
    end

    test "a custom assignment set after a rule win does not expose it again" do
      {ctx, endpoint} = start_context(experiment(rules([assign("All", nil, 1)])))
      assert Context.treatment(ctx, "exp_test_abc") == 1

      :ok = Context.set_custom_assignment(ctx, "exp_test_abc", 0)
      assert Context.treatment(ctx, "exp_test_abc") == 1

      :ok = Context.set_custom_assignments(ctx, %{"exp_test_abc" => 2})
      assert Context.treatment(ctx, "exp_test_abc") == 1

      assert [%{"variant" => 1, "ruleOverride" => true}] = published_exposures(ctx, endpoint)
    end

    test "a refresh that removes the experiment does not serve the stale rule variant" do
      {ctx, endpoint} = start_context(experiment(rules([assign("All", nil, 1)])))
      assert Context.treatment(ctx, "exp_test_abc") == 1

      :ok = Context.refresh(ctx, %{"experiments" => []})

      assert Context.peek(ctx, "exp_test_abc") == 0
      assert Context.treatment(ctx, "exp_test_abc") == 0

      assert [%{"variant" => 1, "ruleOverride" => true}, removed] =
               published_exposures(ctx, endpoint)

      assert %{"id" => 0, "variant" => 0, "assigned" => false, "ruleOverride" => false} = removed
    end
  end

  describe "split rules" do
    test "the unit is hashed with the experiment seed over the rule's percentages" do
      {ctx, _} = start_context(experiment(rules([split("US", @us, "70/10/20")])))
      :ok = Context.set_attribute(ctx, "country", "US")

      assert Context.treatment(ctx, "exp_test_abc") == normal_variant([0.7, 0.1, 0.2])
    end

    test "the only variant with a non-zero share is assigned" do
      for {percentages, expected} <- [{"0/100/0", 1}, {"0/0/100", 2}, {"100/0/0", 0}] do
        {ctx, _} = start_context(experiment(rules([split("All", nil, percentages)])))
        assert Context.treatment(ctx, "exp_test_abc") == expected
      end
    end

    test "the exposure carries the same flags as an assign rule" do
      {ctx, endpoint} = start_context(experiment(rules([split("All", nil, "0/100/0")])))
      Context.treatment(ctx, "exp_test_abc")

      assert [exposure] = published_exposures(ctx, endpoint)

      assert %{
               "variant" => 1,
               "assigned" => false,
               "eligible" => true,
               "custom" => false,
               "ruleOverride" => true
             } = exposure
    end

    test "a split wins over a custom assignment" do
      {ctx, _} =
        start_context(experiment(rules([split("All", nil, "0/100/0")])),
          custom_assignments: %{"exp_test_abc" => 2}
        )

      assert Context.treatment(ctx, "exp_test_abc") == 1
    end

    test "a split that does not cover every variant falls back without trying later rules" do
      {ctx, _} =
        start_context(experiment(rules([split("US", @us, "0/100"), assign("All", nil, 1)])))

      :ok = Context.set_attribute(ctx, "country", "US")
      assert Context.treatment(ctx, "exp_test_abc") == normal_variant()
    end

    test "a split with invalid percentages is skipped" do
      for percentages <- ["50/abc/50", "150/-50/0", "50/49/0", "", [50, 50, 0], "Infinity/0/0"] do
        {ctx, _} =
          start_context(
            experiment(rules([split("bad", nil, percentages), assign("All", nil, 0)]))
          )

        assert Context.treatment(ctx, "exp_test_abc") == 0, inspect(percentages)
      end
    end

    test "without its unit a split gives variant 0 and stops, then re-resolves once it is set" do
      {ctx, _} =
        start_context(
          experiment(rules([split("US", @us, "0/100/0"), assign("All", nil, 2)])),
          units: %{"user_id" => "123"}
        )

      :ok = Context.set_attribute(ctx, "country", "US")
      assert Context.peek(ctx, "exp_test_abc") == 0

      :ok = Context.set_unit(ctx, "session_id", @session)
      assert Context.peek(ctx, "exp_test_abc") == 1
    end

    test "set_units also re-resolves a split resolved without its unit" do
      {ctx, _} =
        start_context(experiment(rules([split("All", nil, "0/100/0")])),
          units: %{"user_id" => "123"}
        )

      assert Context.peek(ctx, "exp_test_abc") == 0

      :ok = Context.set_units(ctx, %{"session_id" => @session})
      assert Context.peek(ctx, "exp_test_abc") == 1
    end

    test "re-resolves once the unit is set when the split starts matching on the same variant" do
      {ctx, _} =
        start_context(
          experiment(rules([split("US", @us, "0/100/0"), assign("All", nil, 0)])),
          units: %{"user_id" => "123"}
        )

      assert Context.peek(ctx, "exp_test_abc") == 0

      :ok = Context.set_attribute(ctx, "country", "US")
      assert Context.peek(ctx, "exp_test_abc") == 0

      :ok = Context.set_unit(ctx, "session_id", @session)
      assert Context.peek(ctx, "exp_test_abc") == 1
    end

    test "an exposed split stays on variant 0 after its unit is set and is exposed only once" do
      {ctx, endpoint} =
        start_context(experiment(rules([split("US", @us, "0/100/0")])),
          units: %{"user_id" => "123"}
        )

      :ok = Context.set_attribute(ctx, "country", "US")
      assert Context.treatment(ctx, "exp_test_abc") == 0

      :ok = Context.set_unit(ctx, "session_id", @session)
      :ok = Context.set_attribute(ctx, "unrelated", true)
      assert Context.treatment(ctx, "exp_test_abc") == 0

      assert [%{"variant" => 0, "ruleOverride" => true}] = published_exposures(ctx, endpoint)
    end

    test "an exposed split stays on variant 0 when a custom assignment lost to it" do
      {ctx, endpoint} =
        start_context(experiment(rules([split("US", @us, "0/100/0")])),
          units: %{"user_id" => "123"},
          custom_assignments: %{"exp_test_abc" => 2}
        )

      :ok = Context.set_attribute(ctx, "country", "US")
      assert Context.treatment(ctx, "exp_test_abc") == 0

      :ok = Context.set_unit(ctx, "session_id", @session)
      assert Context.treatment(ctx, "exp_test_abc") == 0

      assert [%{"variant" => 0}] = published_exposures(ctx, endpoint)
    end

    test "an exposed split stays pinned when a custom assignment is set before its unit" do
      {ctx, endpoint} =
        start_context(experiment(rules([split("All", nil, "0/100/0")])),
          units: %{"user_id" => "123"}
        )

      assert Context.treatment(ctx, "exp_test_abc") == 0

      :ok = Context.set_custom_assignment(ctx, "exp_test_abc", 2)
      :ok = Context.set_unit(ctx, "session_id", @session)
      assert Context.treatment(ctx, "exp_test_abc") == 0

      assert [%{"variant" => 0}] = published_exposures(ctx, endpoint)
    end

    test "an assign rule's cached assignment is kept when the unit is set later" do
      {ctx, _} =
        start_context(experiment(rules([assign("All", nil, 1)])), units: %{"user_id" => "123"})

      assert Context.treatment(ctx, "exp_test_abc") == 1

      :ok = Context.set_unit(ctx, "session_id", @session)
      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.pending(ctx) == 1
    end

    test "without its unit a split on a full-on experiment gives the full-on variant" do
      {ctx, _} =
        start_context(experiment(rules([split("All", nil, "0/100/0")]), full_on_variant: 2),
          units: %{"user_id" => "123"}
        )

      assert Context.peek(ctx, "exp_test_abc") == 2

      :ok = Context.set_unit(ctx, "session_id", @session)
      assert Context.peek(ctx, "exp_test_abc") == 1
    end
  end
end
