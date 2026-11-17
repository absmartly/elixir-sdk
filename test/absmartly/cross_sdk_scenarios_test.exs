defmodule ABSmartly.CrossSDKScenariosTest do
  @moduledoc """
  Replays the cross-SDK conformance scenarios for holdouts (203-227), custom
  assignment rules (230-239, 300-314, 324-330), the semver operators (240-245,
  315-319, 331-332), audience re-evaluation (246-247), system attributes
  (248-253) and blank client applications (322-323) against the real
  `ABSmartly.Context` API.

  A scenario runs unless it `requires` a capability this SDK does not have
  (see `@unsupported`), as in the cross-SDK harness.

  The scenarios are vendored from absmartly/cross-sdk-tests (see the `source`
  field of `test/fixtures/cross_sdk_scenarios.json`); their expected results
  and events were recorded from the JavaScript reference SDK. As in the
  harness, an expected event's `data` is matched on the keys it lists (at
  every depth; lists must have the same length), and a step's `events` must be
  exactly the events that step emitted, in order.

  The fixture stores one scenario per line, so a diff shows which scenarios
  changed. To update it, copy the scenarios from cross-sdk-tests'
  `test_scenarios_complete.json` and update `source`. To review a change field
  by field, use `test/fixtures/diff_scenarios.sh` (needs Bash and `jq`):

      test/fixtures/diff_scenarios.sh HEAD             # uncommitted changes
      test/fixtures/diff_scenarios.sh <sha>^ <sha>     # a committed change
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types}

  @fixture Path.expand("../fixtures/cross_sdk_scenarios.json", __DIR__)
  @external_resource @fixture
  @scenarios @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

  # Capabilities a scenario can require that this SDK does not have, or that
  # this in-process replay cannot drive:
  # - clientRejectsBlankApplication: the SDK accepts a blank application (it
  #   runs clientAcceptsBlankApplication instead).
  # - xAgentHeader: needs real HTTP requests; `ABSmartly.HTTPIntegrationTest`
  #   checks the X-Agent header against these scenarios' patterns.
  @unsupported ["clientRejectsBlankApplication", "xAgentHeader"]

  for scenario <- @scenarios,
      not Enum.any?(scenario["requires"] || [], &(&1 in @unsupported)) do
    @scenario scenario
    test scenario["name"] do
      run_scenario(@scenario)
    end
  end

  # Guards the vendored set: every scenario of the pinned ranges is present,
  # so dropping one while updating the fixture fails here.
  test "the fixture has every scenario of 203-227, 230-253 and 300-332" do
    numbers =
      Enum.map(@scenarios, &(&1["name"] |> String.split(" ") |> hd() |> String.to_integer()))

    assert Enum.sort(numbers) ==
             Enum.to_list(203..227) ++ Enum.to_list(230..253) ++ Enum.to_list(300..332)
  end

  # Guards the gate: every holdout scenario runs here, none is skipped.
  test "every holdout scenario runs" do
    holdout_scenarios =
      Enum.filter(@scenarios, &Enum.any?(&1["requires"] || [], fn r -> r =~ "holdout" end))

    assert length(holdout_scenarios) == 25
    refute Enum.any?(holdout_scenarios, &Enum.any?(&1["requires"], fn r -> r in @unsupported end))
  end

  defp run_scenario(scenario) do
    {:ok, events} = Agent.start_link(fn -> [] end)

    Enum.reduce(scenario["steps"], nil, fn step, ctx ->
      {result, ctx} = run_step(step, ctx, scenario, events)
      emitted = Agent.get_and_update(events, &{Enum.reverse(&1), []})
      expect = step["expect"]

      assert normalize(result) == expect["result"],
             "#{step["action"]} #{inspect(step["params"])}: result #{inspect(result)}"

      expected_events = expect["events"] || []

      assert length(emitted) == length(expected_events),
             "#{step["action"]} #{inspect(step["params"])}: events #{inspect(emitted)}"

      for {{type, data}, expected} <- Enum.zip(emitted, expected_events) do
        assert type == expected["type"]
        if expected["data"], do: assert_subset(expected["data"], data, type)
      end

      ctx
    end)
  end

  # Both create the context from the scenario's data: the harness serves it
  # from its mock collector for createContext.
  defp run_step(%{"action" => create, "params" => params}, nil, scenario, events)
       when create in ["createContext", "createContextWith"] do
    # Without a `client` the harness uses its fixed test application and
    # environment; a `client` that leaves a name out means it is not configured.
    client = params["client"] || %{"application" => "test-app", "environment" => "test"}

    sdk_config = %Types.SDKConfig{
      endpoint: "https://test.absmartly.io/v1",
      api_key: "test-api-key",
      application: client["application"],
      environment: client["environment"],
      publisher: ABSmartly.Test.OkPublisher
    }

    handler = fn type, data -> Agent.update(events, &[{Atom.to_string(type), data} | &1]) end

    context_config =
      (params["options"] || %{})
      |> Map.put("units", params["units"])
      |> Map.put("eventHandler", handler)
      |> Types.ContextConfig.from_options()

    data = Types.ContextData.from_map(scenario["contextData"])
    {:ok, ctx} = Context.start_link(sdk_config, data, context_config)
    {%{"ready" => true, "failed" => false, "finalized" => false}, ctx}
  end

  defp run_step(%{"action" => action, "params" => params}, ctx, _scenario, _events) do
    result =
      case action do
        "treatment" -> Context.treatment(ctx, params["experimentName"])
        "peek" -> Context.peek(ctx, params["experimentName"])
        "pending" -> Context.pending(ctx)
        "attribute" -> ok(Context.set_attribute(ctx, params["name"], params["value"]))
        "override" -> ok(Context.set_override(ctx, params["experimentName"], params["variant"]))
        "customAssignment" -> custom_assignment(ctx, params)
        "variableValue" -> Context.variable_value(ctx, params["key"], params["defaultValue"])
        "peekVariableValue" -> peek_variable_value(ctx, params)
        "publish" -> ok(Context.publish(ctx))
        "refresh" -> ok(Context.refresh(ctx, params["newData"]))
        "setUnit" -> ok(Context.set_unit(ctx, params["unitType"], params["uid"]))
      end

    {result, ctx}
  end

  defp custom_assignment(ctx, params),
    do: ok(Context.set_custom_assignment(ctx, params["experimentName"], params["variant"]))

  defp peek_variable_value(ctx, params),
    do: Context.peek_variable_value(ctx, params["key"], params["defaultValue"])

  defp ok(:ok), do: nil

  # Event payloads are SDK structs; compare them through their wire format.
  defp normalize(%Types.Exposure{} = exposure), do: Types.Exposure.to_map(exposure)
  defp normalize(%Types.ExperimentData{id: id, name: name}), do: %{"id" => id, "name" => name}
  defp normalize(%{} = map) when not is_struct(map), do: Map.new(map, &normalize_entry/1)
  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  defp normalize_entry({key, value}), do: {to_string(key), normalize(value)}

  defp assert_subset(expected, actual, type) do
    actual = normalize(actual)

    for {key, value} <- expected do
      assert Map.has_key?(actual, key) and matches?(Map.get(actual, key), value),
             "#{type} event #{key}: expected #{inspect(value)}, got #{inspect(Map.get(actual, key))}"
    end
  end

  # The harness's values_match: objects match on the keys they list, lists
  # positionally with the same length.
  defp matches?(%{} = actual, %{} = expected),
    do: Enum.all?(expected, fn {k, v} -> Map.has_key?(actual, k) and matches?(actual[k], v) end)

  defp matches?(actual, expected) when is_list(actual) and is_list(expected),
    do:
      length(actual) == length(expected) and
        Enum.all?(Enum.zip(actual, expected), fn {a, e} -> matches?(a, e) end)

  defp matches?(actual, expected), do: actual == expected
end
