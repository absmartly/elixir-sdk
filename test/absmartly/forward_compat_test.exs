defmodule ABSmartly.ForwardCompatTest do
  @moduledoc """
  The context payload must stay forward compatible: unknown fields at any
  level (payload, experiment, variant, rule), unknown rule types and operators,
  and malformed optional `assignmentRules` must not fail the context or affect
  other experiments.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types, Utils, VariantAssigner}

  @holdouts_fixture Path.expand("../fixtures/holdouts_forward_compat.json", __DIR__)

  @session "e791e240fcd3df7d238cfc285f475e8152fcc0ec"

  defp experiment(id, name, assignment_rules, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "iteration" => 1,
        "unitType" => "session_id",
        "seedHi" => 55_006_150,
        "seedLo" => 47_189_152,
        "split" => [0.34, 0.33, 0.33],
        "trafficSeedHi" => 705_671_872,
        "trafficSeedLo" => 212_903_484,
        "trafficSplit" => [0.0, 1.0],
        "fullOnVariant" => 0,
        "applications" => [%{"name" => "website"}],
        "variants" => [
          %{"name" => "A", "config" => nil, "futureField" => 1},
          %{"name" => "B", "config" => "{\"color\":\"blue\"}", "futureField" => [1]},
          %{"name" => "C", "config" => "{\"color\":\"red\"}", "futureField" => %{"x" => 1}}
        ],
        "audience" => nil,
        "audienceStrict" => false,
        "customFieldValues" => nil,
        "assignmentRules" => assignment_rules
      },
      extra
    )
  end

  defp normal_variant,
    do:
      VariantAssigner.assign(
        Utils.hash_unit(@session),
        [0.34, 0.33, 0.33],
        55_006_150,
        47_189_152
      )

  # Goes through the same decoding as a fetched payload.
  defp start_context(payload, units \\ %{"session_id" => @session}) do
    {:ok, data} = payload |> Jason.encode!() |> Jason.decode!() |> Context.safe_context_data()

    sdk_config = %Types.SDKConfig{
      endpoint: "https://test.absmartly.io/v1",
      api_key: "test-api-key",
      application: "website",
      environment: "production",
      publisher: ABSmartly.Test.OkPublisher
    }

    context_config = %Types.ContextConfig{
      units: units,
      attributes: [],
      overrides: %{},
      custom_assignments: %{}
    }

    {:ok, ctx} = Context.start_link(sdk_config, data, context_config)
    ctx
  end

  test "unknown fields at every level are ignored" do
    rules =
      Jason.encode!(%{
        "futureField" => true,
        "rules" => [
          %{
            "name" => "all",
            "type" => "assign",
            "variant" => 1,
            "futureField" => %{"nested" => [1, 2]},
            "conditions" => %{"value" => true}
          }
        ]
      })

    ctx =
      start_context(%{
        "futureField" => %{"anything" => [1, "two"]},
        "experiments" => [
          experiment(1, "exp_rules", rules, %{"futureField" => "x", "futureList" => [1]})
        ]
      })

    assert Context.is_ready?(ctx)
    assert Context.treatment(ctx, "exp_rules") == 1
    assert Context.variable_value(ctx, "color", "none") == "blue"
  end

  test "unknown rule types and operators are skipped for the next rule" do
    rules =
      Jason.encode!(%{
        "rules" => [
          %{"type" => "futureType", "variant" => 0},
          %{"type" => "assign", "variant" => 0, "conditions" => %{"future_op" => [1, 2]}},
          %{"type" => "assign", "variant" => 1}
        ]
      })

    ctx = start_context(%{"experiments" => [experiment(1, "exp_rules", rules)]})
    assert Context.treatment(ctx, "exp_rules") == 1
  end

  test "malformed optional assignmentRules only affect their own experiment" do
    valid = Jason.encode!(%{"rules" => [%{"type" => "assign", "variant" => 1}]})

    malformed = [
      nil,
      "",
      "not json",
      "null",
      "[]",
      "{\"rules\":null}",
      "{\"rules\":\"x\"}",
      "{\"rules\":[null, 1, \"x\", []]}",
      42,
      %{"rules" => []},
      ["rules"]
    ]

    bad =
      malformed |> Enum.with_index(2) |> Enum.map(fn {r, i} -> experiment(i, "bad_#{i}", r) end)

    ctx =
      start_context(%{
        "experiments" => [experiment(1, "first", valid)] ++ bad ++ [experiment(99, "last", valid)]
      })

    assert Context.treatment(ctx, "first") == 1
    assert Context.treatment(ctx, "last") == 1

    for %{"name" => name, "assignmentRules" => r} <- bad do
      assert Context.treatment(ctx, name) == normal_variant(), inspect(r)
    end
  end

  test "unknown and malformed fields in holdouts are ignored, with no log output" do
    payload = @holdouts_fixture |> File.read!() |> Jason.decode!()

    # Decoding runs in this process and evaluation in the context's, so only
    # their log events count: other tests run concurrently (async: true).
    {log, ctx} =
      log_events_of_self_and_context(fn ->
        start_context(payload, %{"session_id" => @session, "user_id" => @session})
      end)

    assert Context.is_ready?(ctx)

    # Holdout 11 holds the unit out, so the union suppresses exp_covered_a.
    assert Context.treatment(ctx, "exp_covered_a") == 0
    assert Context.variable_value(ctx, "color", "none") == "none"
    # Only holdout 12 is a valid covering holdout for exp_covered_b, and it
    # does not hold the unit out (on the experiment's own unit type).
    assert Context.treatment(ctx, "exp_covered_b") == 1
    # A holdoutIds value that is not a list covers nothing.
    assert Context.treatment(ctx, "exp_bad_holdout_ids") == 1

    exposures =
      for e <- pending_exposures(ctx),
          do: {e.id, e.name, e.unit, e.variant}

    assert exposures == [
             {11, "holdout_a", "session_id", 0},
             {12, "holdout_b", "session_id", 1},
             {2, "exp_covered_b", "user_id", 1},
             {12, "holdout_b", "user_id", 1},
             {3, "exp_bad_holdout_ids", "session_id", 1}
           ]

    data = Context.data(ctx)
    assert Enum.map(data.experiments, & &1.holdout_ids) == [[11, 12], [12, 99], nil]
    assert Enum.map(data.experiments, & &1.holdout_type) == ["full", nil, nil]
    assert Enum.map(data.holdouts, & &1.id) == [11, 12, 14, 15]
    assert Enum.find(data.holdouts, &(&1.id == 14)).split == []
    assert %{seed_hi: 0, seed_lo: 0, iteration: 0} = Enum.find(data.holdouts, &(&1.id == 15))

    assert log.() == []
  end

  # Runs `fun` (which returns the context) with a logger handler that keeps
  # the warning-or-above events of this process and of the processes it
  # starts (the context, from its init on). Returns a function reading them,
  # which also removes the handler, and the context.
  defp log_events_of_self_and_context(fun) do
    test_pid = self()
    {:ok, events} = Agent.start_link(fn -> [] end)
    pids = :ets.new(:log_pids, [:public, :set])
    :ets.insert(pids, {test_pid})
    id = :"holdout_log_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(id, __MODULE__.LogSink, %{
        level: :warning,
        config: %{events: events, pids: pids}
      })

    on_exit(fn -> :logger.remove_handler(id) end)

    ctx = fun.()

    {fn ->
       # A synchronous call, so the context's earlier logging has run.
       :sys.get_state(ctx)
       :logger.remove_handler(id)
       Agent.get(events, &Enum.reverse/1)
     end, ctx}
  end

  defmodule LogSink do
    @moduledoc false
    # Runs in the logging process: an event counts when that process, or the
    # process that started it, is the test's.
    def log(%{level: level, msg: msg}, %{config: %{events: events, pids: pids}}) do
      if :ets.info(pids) != :undefined and
           Enum.any?([self() | Process.get(:"$ancestors", [])], &:ets.member(pids, &1)),
         do: Agent.update(events, &[{level, msg} | &1])
    end
  end

  defp pending_exposures(ctx), do: :sys.get_state(ctx).exposures |> Enum.reverse()
end
