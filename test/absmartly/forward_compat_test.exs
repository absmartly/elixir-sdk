defmodule ABSmartly.ForwardCompatTest do
  @moduledoc """
  The context payload must stay forward compatible: unknown fields at any
  level (payload, experiment, variant, rule), unknown rule types and operators,
  and malformed optional `assignmentRules` must not fail the context or affect
  other experiments.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types, Utils, VariantAssigner}

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
  defp start_context(payload) do
    {:ok, data} = payload |> Jason.encode!() |> Jason.decode!() |> Context.safe_context_data()

    sdk_config = %Types.SDKConfig{
      endpoint: "https://test.absmartly.io/v1",
      api_key: "test-api-key",
      application: "website",
      environment: "production",
      publisher: ABSmartly.Test.OkPublisher
    }

    context_config = %Types.ContextConfig{
      units: %{"session_id" => @session},
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
end
