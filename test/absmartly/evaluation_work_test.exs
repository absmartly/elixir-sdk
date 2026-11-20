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

  @build {ABSmartly.Context, :build_evaluation_vars, 1}
  @rules {ABSmartly.Matcher, :evaluate_rules, 3}

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

  # The switchback key path is chosen at data install, so a variable read
  # without switchbacks does no per-read switchback work.
  test "a variable read without switchbacks never takes the switchback path" do
    experiments =
      for i <- 1..10 do
        experiment("plain_#{i}")
        |> Map.put("variants", [
          %{"name" => "A", "config" => ~s({"color":"red"})},
          %{"name" => "B", "config" => ~s({"color":"blue"})}
        ])
      end

    ctx = start_context(experiments, [])
    switchback = {ABSmartly.Context, :switchback_variable_value, 5}
    candidate = {ABSmartly.Context, :variable_candidate, 3}

    counts =
      count_calls(ctx, [switchback, candidate], fn ->
        for _ <- 1..20, do: Context.variable_value(ctx, "color", "none")
      end)

    assert counts == %{switchback => 0, candidate => 0}
    assert :sys.get_state(ctx).switchback_variable_index == %{}
  end

  # The switchback key path is a map lookup chosen at data install. A read
  # of a key shared by 40 unit experiments, where the first one wins, does
  # the same work whether or not the payload has a switchback, and that work
  # does not grow with the key's experiments (a per-read scan of them would
  # about double it).
  test "a unit-only variable read does no per-read work for its key's experiments" do
    config = [
      %{"name" => "A", "config" => ~s({"color":"red"})},
      %{"name" => "B", "config" => ~s({"color":"blue"})}
    ]

    switchback =
      experiment("sb")
      |> Map.merge(%{
        "randomizationType" => "switchback",
        "switchbackClusters" => %Jason.OrderedObject{values: [{"session_id", "city"}]},
        "switchbackStartAt" => 0,
        "switchbackPeriodMs" => 3_600_000,
        "variants" => [
          %{"name" => "A", "config" => ~s({"size":1})},
          %{"name" => "B", "config" => ~s({"size":2})}
        ]
      })

    reductions = fn experiments ->
      ctx = start_context(experiments, [])
      for _ <- 1..20, do: Context.variable_value(ctx, "color", "none")
      {:reductions, before} = Process.info(ctx, :reductions)
      for _ <- 1..200, do: Context.variable_value(ctx, "color", "none")
      {:reductions, later} = Process.info(ctx, :reductions)
      div(later - before, 200)
    end

    units = fn n -> for i <- 1..n, do: experiment("plain_#{i}") |> Map.put("variants", config) end

    one = reductions.(units.(1))
    forty = reductions.(units.(40))
    forty_with_switchback = reductions.(units.(40) ++ [switchback])

    assert forty - one <= 20, "1 vs 40 experiments: #{one} vs #{forty} reductions per read"

    assert forty_with_switchback - forty <= 20,
           "#{forty} vs #{forty_with_switchback} reductions per read"
  end

  # Installing data without switchbacks never scans the variable index for
  # switchback keys.
  test "installing data without switchbacks does no switchback key work" do
    config = [%{"name" => "A", "config" => ~s({"color":"red","size":1})}]
    experiments = for i <- 1..20, do: experiment("plain_#{i}") |> Map.put("variants", config)
    ctx = start_context(experiments, [])
    scan = {Enum, :any?, 2}

    counts =
      count_calls(ctx, [scan], fn ->
        :ok = Context.set_data(ctx, %{"experiments" => experiments})
      end)

    assert counts == %{scan => 0}
    assert :sys.get_state(ctx).switchback_variable_index == %{}
  end
end
