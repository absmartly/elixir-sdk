defmodule ABSmartly.EvaluationWorkTest do
  @moduledoc """
  Bounds the work done to assign: the attribute map that rules and audiences
  are evaluated against is only built when an experiment has rules or an
  audience, at most once per attribute change, and a cached assignment is only
  re-checked once after an attribute change or a refresh.

  Counts calls made by the context process with call tracing, so it is not
  async (trace patterns are global).
  """

  use ExUnit.Case, async: false

  alias ABSmartly.{Context, Types}

  @session "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
  @us %{"eq" => [%{"var" => "country"}, %{"value" => "US"}]}

  defp experiment(name, opts \\ []) do
    %{
      "id" => :erlang.phash2(name),
      "name" => name,
      "iteration" => 1,
      "unitType" => "session_id",
      "seedHi" => 55_006_150,
      "seedLo" => 47_189_152,
      "split" => [0.5, 0.5],
      "trafficSeedHi" => 705_671_872,
      "trafficSeedLo" => 212_903_484,
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => 0,
      "applications" => [%{"name" => "website"}],
      "variants" => [%{"name" => "A", "config" => nil}, %{"name" => "B", "config" => nil}],
      "audience" => Keyword.get(opts, :audience),
      "audienceStrict" => false,
      "customFieldValues" => nil,
      "assignmentRules" => Keyword.get(opts, :rules)
    }
  end

  defp rules(rule_name, variant) do
    Jason.encode!(%{
      "rules" => [
        %{"name" => rule_name, "type" => "assign", "conditions" => @us, "variant" => variant}
      ]
    })
  end

  defp start_context(experiments, attributes, holdouts \\ []) do
    sdk_config = %Types.SDKConfig{
      endpoint: "https://test.absmartly.io/v1",
      api_key: "test-api-key",
      application: "website",
      environment: "production",
      publisher: ABSmartly.Test.OkPublisher
    }

    context_config = %Types.ContextConfig{
      units: %{"session_id" => @session},
      attributes: attributes,
      overrides: %{},
      custom_assignments: %{}
    }

    data = Types.ContextData.from_map(%{"experiments" => experiments, "holdouts" => holdouts})
    {:ok, ctx} = Context.start_link(sdk_config, data, context_config)
    ctx
  end

  defp many_attributes(count),
    do: Enum.map(1..count, &%{"name" => "attr_#{&1}", "value" => &1})

  # Runs `fun` and returns how many times the context process called each of
  # `mfas`.
  defp count_calls(ctx, mfas, fun) do
    :erlang.trace(ctx, true, [:call, {:tracer, self()}])
    Enum.each(mfas, &:erlang.trace_pattern(&1, true, [:local]))

    try do
      fun.()
      # A synchronous call, so `fun`'s calls have all run, then wait until
      # every trace message they generated has been delivered.
      Context.pending(ctx)
      ref = :erlang.trace_delivered(ctx)

      receive do
        {:trace_delivered, ^ctx, ^ref} -> :ok
      end

      Map.new(mfas, &{&1, drain(&1, 0)})
    after
      Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:local]))
      :erlang.trace(ctx, false, [:call])
    end
  end

  defp drain({m, f, a} = mfa, count) do
    receive do
      {:trace, _pid, :call, {^m, ^f, args}} when length(args) == a -> drain(mfa, count + 1)
    after
      0 -> count
    end
  end

  test "overridden covered reads reuse the installed holdout index" do
    experiment = experiment("covered") |> Map.put("holdoutIds", [11])
    holdout = %{"id" => 11, "name" => "h", "seedHi" => 0, "seedLo" => 0, "split" => [1.0, 0.0]}
    ctx = start_context([experiment], [], [holdout])
    :ok = Context.set_override(ctx, "covered", 1)
    build = {Context, :build_holdout_index, 1}

    counts =
      count_calls(ctx, [build], fn ->
        Enum.each(1..10, fn _ -> assert Context.peek(ctx, "covered") == 1 end)
      end)

    assert counts == %{build => 0}
  end

  test "data installs without exposed holdouts skip the pruning walk" do
    experiments = Enum.map(1..1000, &experiment("plain_#{&1}"))
    ctx = start_context(experiments, [])
    Enum.each(experiments, &Context.peek(ctx, &1["name"]))
    data = %{"experiments" => experiments}
    walk = {Context, :reachable_arm_refs, 1}
    intersect = {MapSet, :intersection, 2}

    for install <- [&Context.set_data/2, &Context.refresh/2] do
      counts =
        count_calls(ctx, [walk, intersect], fn -> :ok = install.(ctx, %{"experiments" => []}) end)

      assert counts == %{walk => 0, intersect => 0}
      :ok = Context.set_data(ctx, data)
      Enum.each(experiments, &Context.peek(ctx, &1["name"]))
    end
  end

  @build {ABSmartly.Context, :build_evaluation_vars, 1}
  @rules {ABSmartly.Matcher, :evaluate_rules, 3}

  test "a unit of another type does not re-resolve a covered decision waiting for its unit" do
    experiment =
      experiment("covered") |> Map.merge(%{"unitType" => "user_id", "holdoutIds" => [11]})

    holdout = %{"id" => 11, "name" => "h", "seedHi" => 0, "seedLo" => 0, "split" => [1.0, 0.0]}
    ctx = start_context([experiment], [], [holdout])
    Context.peek(ctx, "covered")
    assign = {Context, :assign_variant, 2}

    counts =
      count_calls(ctx, [assign], fn ->
        :ok = Context.set_units(ctx, %{"other_id" => "o1"})
        Context.peek(ctx, "covered")
      end)

    assert counts == %{assign => 0}
  end

  test "a differing custom write does not re-resolve a rule-won covered decision" do
    experiment =
      experiment("covered", rules: rules("r", 1))
      |> Map.merge(%{"unitType" => "user_id", "holdoutIds" => [11]})

    holdout = %{"id" => 11, "name" => "h", "seedHi" => 0, "seedLo" => 0, "split" => [0.0, 1.0]}
    ctx = start_context([experiment], [%{"name" => "country", "value" => "US"}], [holdout])
    assert Context.treatment(ctx, "covered") == 1
    assign = {Context, :assign_variant, 2}

    counts =
      count_calls(ctx, [assign], fn ->
        :ok = Context.set_custom_assignment(ctx, "covered", 0)
        :ok = Context.set_unit(ctx, "user_id", "u1")
        assert Context.treatment(ctx, "covered") == 1
      end)

    assert counts == %{assign => 0}
  end

  test "cached reads without custom assignments never check them for staleness" do
    ctx = start_context([experiment("plain")], [])
    assert Context.peek(ctx, "plain") in [0, 1]
    check = {Context, :custom_stale?, 3}

    counts =
      count_calls(ctx, [check], fn ->
        Enum.each(1..10, fn _ -> Context.peek(ctx, "plain") end)
      end)

    assert counts == %{check => 0}
  end

  test "cached reads of a payload without holdouts never look up holdout keys" do
    ctx = start_context([experiment("plain")], [])
    assert Context.peek(ctx, "plain") in [0, 1]
    lookup = {Context, :holdout_key, 2}

    counts =
      count_calls(ctx, [lookup], fn ->
        Enum.each(1..10, fn _ -> Context.peek(ctx, "plain") end)
      end)

    assert counts == %{lookup => 0}
  end

  test "normal reads without overrides leave the override snapshots untouched" do
    ctx = start_context([experiment("plain")], [])
    assert Context.peek(ctx, "plain") in [0, 1]
    delete = {:maps, :remove, 2}

    counts =
      count_calls(ctx, [delete], fn ->
        Enum.each(1..10, fn _ -> Context.peek(ctx, "plain") end)
      end)

    assert counts == %{delete => 0}
  end

  test "a holdout iteration change re-resolves with one evaluation map per attribute change" do
    names = Enum.map(1..40, &"covered_#{&1}")

    holdout = fn iteration ->
      %{
        "id" => 11,
        "name" => "h",
        "iteration" => iteration,
        "seedHi" => 0,
        "seedLo" => 0,
        "split" => [0.0, 1.0]
      }
    end

    experiments =
      Enum.map(names, &(experiment(&1, rules: rules("r", 1)) |> Map.put("holdoutIds", [11])))

    attributes = [%{"name" => "country", "value" => "US"} | many_attributes(500)]
    ctx = start_context(experiments, attributes, [holdout.(1)])
    Enum.each(names, &assert(Context.treatment(ctx, &1) == 1))
    exposed = Context.pending(ctx)

    counts =
      count_calls(ctx, [@build], fn ->
        # Leaves every rule outcome unchanged: only the holdout bump re-resolves.
        :ok = Context.set_attribute(ctx, "unrelated", true)
        :ok = Context.refresh(ctx, %{"experiments" => experiments, "holdouts" => [holdout.(2)]})
        Enum.each(names, &assert(Context.treatment(ctx, &1) == 1))
      end)

    assert counts == %{@build => 1}
    assert Context.pending(ctx) - exposed == 41
  end

  test "experiments without rules or an audience never build the evaluation map" do
    names = Enum.map(1..20, &"plain_#{&1}")
    ctx = start_context(Enum.map(names, &experiment/1), many_attributes(200))

    counts =
      count_calls(ctx, [@build, @rules], fn ->
        Enum.each(names, &Context.treatment(ctx, &1))
        :ok = Context.set_attribute(ctx, "country", "US")
        Enum.each(names, &Context.treatment(ctx, &1))
      end)

    assert counts == %{@build => 0, @rules => 0}
  end

  test "the evaluation map is built once per attribute change, shared by every experiment" do
    names = Enum.map(1..20, &"ruled_#{&1}")
    audience = Jason.encode!(%{"filter" => [@us]})

    experiments =
      Enum.map(names, fn name ->
        if rem(:erlang.phash2(name), 2) == 0,
          do: experiment(name, rules: rules("r", 1)),
          else: experiment(name, audience: audience)
      end)

    ctx = start_context(experiments, many_attributes(200))

    counts =
      count_calls(ctx, [@build], fn ->
        Enum.each(names, &Context.treatment(ctx, &1))
        :ok = Context.set_attribute(ctx, "country", "US")
        Enum.each(names, &Context.treatment(ctx, &1))
        Enum.each(names, &Context.treatment(ctx, &1))
      end)

    assert counts == %{@build => 2}
  end

  test "after an unrelated attribute change, rules are re-checked once, not on every read" do
    ctx = start_context([experiment("exp", rules: rules("r", 1))], [])
    :ok = Context.set_attribute(ctx, "country", "US")
    assert Context.treatment(ctx, "exp") == 1

    counts =
      count_calls(ctx, [@rules], fn ->
        :ok = Context.set_attribute(ctx, "unrelated", true)
        for _ <- 1..5, do: assert(Context.treatment(ctx, "exp") == 1)
      end)

    assert counts == %{@rules => 1}
    assert Context.pending(ctx) == 1
  end

  test "after a refresh with the same rule outcome, rules are re-checked once, not on every read" do
    ctx = start_context([experiment("exp", rules: rules("r", 1))], [])
    :ok = Context.set_attribute(ctx, "country", "US")
    assert Context.treatment(ctx, "exp") == 1

    counts =
      count_calls(ctx, [@rules], fn ->
        :ok =
          Context.refresh(ctx, %{"experiments" => [experiment("exp", rules: rules("renamed", 1))]})

        for _ <- 1..5, do: assert(Context.treatment(ctx, "exp") == 1)
      end)

    assert counts == %{@rules => 1}
    assert Context.pending(ctx) == 1
  end

  @audience {ABSmartly.Matcher, :evaluate, 2}

  # A held-out unit's assignment never evaluates its audience (the JavaScript
  # SDK skips it), not on assignment and not after an attribute change.
  test "a suppressed experiment never evaluates its audience" do
    experiment =
      experiment("exp_held_out", audience: Jason.encode!(%{"filter" => [@us]}))
      |> Map.put("holdoutIds", [11])

    holdout = %{"id" => 11, "name" => "h", "seedHi" => 0, "seedLo" => 0, "split" => [1.0, 0.0]}

    ctx = start_context([experiment], [], [holdout])

    counts =
      count_calls(ctx, [@audience], fn ->
        assert Context.treatment(ctx, "exp_held_out") == 0
        :ok = Context.set_attribute(ctx, "country", "US")
        assert Context.treatment(ctx, "exp_held_out") == 0
        :ok = Context.set_attribute(ctx, "country", "GB")
        assert Context.treatment(ctx, "exp_held_out") == 0
      end)

    assert counts == %{@audience => 0}
    assert Context.pending(ctx) == 1
  end
end
