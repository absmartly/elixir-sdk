defmodule ABSmartly.CrossSDKScenariosTest.Ordered do
  @moduledoc false
  # Turns a scenario decoded with ordered objects back into plain JSON maps,
  # except its context data (`contextData`, a refresh's `newData`), which is
  # kept as its JSON text: the test decodes it with the SDK's decoder, as the
  # SDK's fetch would.

  def scenario(%Jason.OrderedObject{values: values}) do
    Map.new(values, fn
      {"contextData", data} -> {"contextData", {:context_data, Jason.encode!(data)}}
      {"steps", steps} -> {"steps", Enum.map(steps, &step/1)}
      {key, value} -> {key, plain(value)}
    end)
  end

  defp step(%Jason.OrderedObject{values: values}) do
    Map.new(values, fn
      {"params", %Jason.OrderedObject{values: params}} ->
        {"params",
         Map.new(params, fn
           {"newData", data} -> {"newData", {:context_data, Jason.encode!(data)}}
           {key, value} -> {key, plain(value)}
         end)}

      {key, value} ->
        {key, plain(value)}
    end)
  end

  defp plain(%Jason.OrderedObject{values: values}),
    do: values |> Enum.reverse() |> Map.new(fn {k, v} -> {k, plain(v)} end)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(other), do: other
end

defmodule ABSmartly.CrossSDKScenariosTest do
  @moduledoc """
  Replays the cross-SDK conformance scenarios for holdouts (203-227), custom
  assignment rules (230-239, 300-314, 324-330), the semver operators (240-245,
  315-319, 331-332), audience re-evaluation (246-247), system attributes
  (248-253), blank client applications (322-323) and switchbacks (400-425:
  the golden vectors, cluster serving, precedence and exposures; 421 is the
  ungated inertness baseline) against the real `ABSmartly.Context` API.

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
  # Decoded with ordered objects, so each scenario's context data can be
  # decoded the way the SDK's fetch decodes it (see as_fetched/1).
  @scenarios @fixture
             |> File.read!()
             |> Jason.decode!(objects: :ordered_objects)
             |> then(&elem(List.keyfind(&1.values, "scenarios", 0), 1))
             |> Enum.map(&ABSmartly.CrossSDKScenariosTest.Ordered.scenario/1)

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
  test "the fixture has every scenario of 203-227, 230-253, 300-332 and 400-425" do
    numbers =
      Enum.map(@scenarios, &(&1["name"] |> String.split(" ") |> hd() |> String.to_integer()))

    assert Enum.sort(numbers) ==
             Enum.to_list(203..227) ++
               Enum.to_list(230..253) ++ Enum.to_list(300..332) ++ Enum.to_list(400..425)
  end

  test "every holdout scenario runs" do
    holdout_scenarios =
      Enum.filter(@scenarios, &Enum.any?(&1["requires"] || [], fn r -> r =~ "holdout" end))

    assert length(holdout_scenarios) == 25
    refute Enum.any?(holdout_scenarios, &Enum.any?(&1["requires"], fn r -> r in @unsupported end))
  end

  test "every switchback scenario runs" do
    switchback_scenarios =
      Enum.filter(@scenarios, &(&1["name"] =~ " - Switchback - "))

    assert length(switchback_scenarios) == 26

    refute Enum.any?(
             switchback_scenarios,
             &Enum.any?(&1["requires"] || [], fn r -> r in @unsupported end)
           )
  end

  defp run_scenario(scenario) do
    {:ok, events} = Agent.start_link(fn -> [] end)

    scenario["steps"]
    |> Enum.with_index()
    |> Enum.reduce({nil, %{}}, fn {step, index}, {ctx, earlier} ->
      {result, ctx} = run_step(step, ctx, scenario, events)
      emitted = Agent.get_and_update(events, &{Enum.reverse(&1), []})
      expect = step["expect"]

      assert normalize(result) == expect["result"],
             "#{step["action"]} #{inspect(step["params"])}: result #{inspect(result)}"

      expected_events = expect["events"] || []

      assert length(emitted) == length(expected_events),
             "#{step["action"]} #{inspect(step["params"])}: events #{inspect(emitted)}"

      emitted
      |> Enum.zip(expected_events)
      |> Enum.with_index()
      |> Enum.each(fn {{{type, data}, expected}, i} ->
        assert type == expected["type"]
        if expected["data"], do: assert_subset(unordered_units(expected, data), data, type)
        if ref = expected["sameShapeAs"], do: assert_same_shape(earlier, ref, i, data, type)
      end)

      {ctx, Map.put(earlier, index, Enum.map(emitted, fn {_type, data} -> normalize(data) end))}
    end)
  end

  # The harness's unorderedUnits: a publish event's units match one-to-one in
  # any order, so the expected units are put in the published order first.
  defp unordered_units(%{"unorderedUnits" => true, "data" => %{"units" => units} = data}, actual) do
    published = normalize(actual)["units"]

    if Enum.sort(units) == Enum.sort(published),
      do: Map.put(data, "units", published),
      else: data
  end

  defp unordered_units(expected, _actual), do: expected["data"]

  # The harness's sameShapeAs: the event has the same keys (at every depth)
  # and list lengths as event `i` of the earlier step `ref`; values are
  # checked by `data`.
  defp assert_same_shape(earlier, ref, i, data, type) do
    reference = earlier |> Map.fetch!(ref) |> Enum.fetch!(i)

    assert shape(normalize(data)) == shape(reference),
           "#{type} event: not the same shape as step #{ref} event #{i}"
  end

  defp shape(%{} = map), do: Map.new(map, fn {k, v} -> {k, shape(v)} end)
  defp shape(list) when is_list(list), do: Enum.map(list, &shape/1)
  defp shape(_scalar), do: :scalar

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

    data = Types.ContextData.from_map(as_fetched(scenario["contextData"]))
    {:ok, ctx} = Context.start_link(sdk_config, data, context_config)
    {%{"ready" => true, "failed" => false, "finalized" => false}, ctx}
  end

  # The pure-function switchback endpoints: 64-bit values travel as decimal
  # strings.
  defp run_step(%{"action" => "switchbackAssign", "params" => p}, ctx, _scenario, _events) do
    result =
      ABSmartly.Switchback.Assigner.assign(
        p["clusterUnit"],
        String.to_integer(p["periodIndex"]),
        String.to_integer(p["seed"]),
        p["armCount"]
      )

    {result, ctx}
  end

  defp run_step(%{"action" => "switchbackPermutation", "params" => p}, ctx, _scenario, _events) do
    base =
      ABSmartly.Switchback.Assigner.base_hash(
        p["clusterUnit"],
        String.to_integer(p["cycleIndex"]),
        String.to_integer(p["seed"])
      )

    {Tuple.to_list(ABSmartly.Switchback.Assigner.fisher_yates_permutation(p["armCount"], base)),
     ctx}
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
        "refresh" -> ok(Context.refresh(ctx, as_fetched(params["newData"])))
        "setUnit" -> ok(Context.set_unit(ctx, params["unitType"], params["uid"]))
      end

    {result, ctx}
  end

  # A scenario's context data, decoded as the SDK's own fetch decodes it.
  defp as_fetched({:context_data, json}) do
    {:ok, data} = ABSmartly.Switchback.Json.decode(json)
    data
  end

  defp as_fetched(other), do: other

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
