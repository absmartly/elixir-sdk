defmodule ABSmartly.CrossSDKScenariosTest do
  @moduledoc ~S"""
  Replays the cross-SDK conformance scenarios for custom assignment rules
  (230-239), the semver operators (240-245), audience re-evaluation (246-247)
  and system attributes (248-253) against the real `ABSmartly.Context` API.

  The scenarios are vendored from absmartly/cross-sdk-tests (see the `source`
  field of `test/fixtures/cross_sdk_scenarios.json`); their expected results
  and events were recorded from the JavaScript reference SDK. As in the
  harness, an expected event's `data` is matched on the keys it lists, and a
  step's `events` must be exactly the events that step emitted, in order.

  The fixture stores one scenario per line, so a diff shows which scenarios
  changed. To update it, copy the scenarios from cross-sdk-tests'
  `test_scenarios_complete.json` and update `source`. To review a change field
  by field, compare pretty-printed copies. Run from the repository root, in
  Bash, with `jq`:

      fixture=test/fixtures/cross_sdk_scenarios.json

      # fixture_diff OLD_REV [NEW_REV]: compares the fixture at OLD_REV with
      # NEW_REV, or with the working tree. Both revisions are checked first,
      # so a typo stops with an error instead of diffing an empty file.
      fixture_diff() {
        local rev
        for rev in "$@"; do
          git rev-parse -q --verify "$rev:$fixture" >/dev/null ||
            { echo "error: no $fixture at $rev" >&2; return 2; }
        done
        local old=$(mktemp) new=$(mktemp)
        git show "$1:$fixture" | jq . >"$old"
        if [ -n "$2" ]; then git show "$2:$fixture" | jq . >"$new"; else jq . "$fixture" >"$new"; fi
        git diff --no-index "$old" "$new"
        local status=$?
        rm -f "$old" "$new"
        return $status
      }

      # Uncommitted changes, against the last commit that touched the fixture:
      fixture_diff "$(git log -1 --format=%H -- "$fixture")"

      # A committed change <sha>, against its parent:
      fixture_diff <sha>^ <sha>
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types}

  @fixture Path.expand("../fixtures/cross_sdk_scenarios.json", __DIR__)
  @external_resource @fixture
  @scenarios @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

  for scenario <- @scenarios do
    @scenario scenario
    test scenario["name"] do
      run_scenario(@scenario)
    end
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

  defp run_step(%{"action" => "createContextWith", "params" => params}, nil, scenario, events) do
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
        "refresh" -> ok(Context.refresh(ctx, params["newData"]))
      end

    {result, ctx}
  end

  defp custom_assignment(ctx, params),
    do: ok(Context.set_custom_assignment(ctx, params["experimentName"], params["variant"]))

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
      assert Map.get(actual, key) == value,
             "#{type} event #{key}: expected #{inspect(value)}, got #{inspect(Map.get(actual, key))}"
    end
  end
end
