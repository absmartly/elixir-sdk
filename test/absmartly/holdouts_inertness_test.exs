defmodule ABSmartly.HoldoutsInertnessTest do
  @moduledoc """
  Without holdouts nothing changes: variants, peeks, variable values and the
  published body (exposures, goals, attributes, units, with timestamps
  normalized) are equal to those recorded from main before holdouts were added
  (`test/fixtures/publish_without_holdouts.json`), for a sweep of unit ids
  over experiments with rules, audiences, full-on, traffic and several unit
  types. An empty `holdouts` list, and holdouts no experiment refers to, are
  inert too.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types}

  @fixture Path.expand("../fixtures/publish_without_holdouts.json", __DIR__)
  @external_resource @fixture
  @recorded @fixture |> File.read!() |> Jason.decode!()

  @uids [
    "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
    " padded ",
    "façade",
    "日本語",
    "🚀emoji",
    "0",
    -42,
    9_007_199_254_740_993,
    125.75,
    12345
  ]

  defmodule Publisher do
    @moduledoc false
    @behaviour ABSmartly.ContextPublisher

    @impl ABSmartly.ContextPublisher
    def publish(endpoint, _api_key, _application, _environment, event_map, _retries) do
      send(:erlang.binary_to_term(Base.decode64!(endpoint)), {:published, event_map})
      :ok
    end
  end

  defp session(payload, uid) do
    {:ok, data} = Context.safe_context_data(payload)

    sdk_config = %Types.SDKConfig{
      endpoint: Base.encode64(:erlang.term_to_binary(self())),
      api_key: "k",
      application: "website",
      environment: "production",
      publisher: Publisher
    }

    units = %{"session_id" => uid, "user_id" => "u-#{inspect(uid)}"}
    {:ok, ctx} = Context.start_link(sdk_config, data, %Types.ContextConfig{units: units})
    :ok = Context.set_attribute(ctx, "country", "US")
    :ok = Context.set_attribute(ctx, "age", 30)
    names = Enum.map(data.experiments, & &1.name)
    peeks = Enum.map(names, &Context.peek(ctx, &1))
    treatments = Enum.map(names, &Context.treatment(ctx, &1))
    vars = Enum.map(["color", "size", "missing"], &Context.variable_value(ctx, &1, "dflt"))
    pvars = Enum.map(["color", "size"], &Context.peek_variable_value(ctx, &1, "dflt"))
    :ok = Context.track(ctx, "goal", %{"amount" => 1})
    :ok = Context.publish(ctx)
    assert_receive {:published, body}

    zero = fn list, key -> Enum.map(list, &Map.put(&1, key, 0)) end

    publish =
      body
      |> Map.put("publishedAt", 0)
      |> Map.update!("exposures", &zero.(&1, "exposedAt"))
      |> Map.update!("goals", &zero.(&1, "achievedAt"))
      |> Map.update!("attributes", &zero.(&1, "setAt"))

    %{
      "uid" => inspect(uid),
      "peeks" => peeks,
      "treatments" => treatments,
      "vars" => vars,
      "pvars" => pvars,
      "publish" => publish
    }
  end

  # Round-tripped through JSON, as the default publisher would send it.
  defp sessions(payload) do
    Enum.map(@uids, &(payload |> session(&1) |> Jason.encode!() |> Jason.decode!()))
  end

  test "a payload without holdouts publishes exactly what main published" do
    assert sessions(@recorded["payload"]) == @recorded["sessions"]
  end

  test "an empty holdouts list is inert" do
    assert sessions(Map.put(@recorded["payload"], "holdouts", [])) == @recorded["sessions"]
  end

  test "holdouts that cover no experiment are inert" do
    holdout = %{"id" => 11, "name" => "h", "seedHi" => 13, "seedLo" => 111, "split" => [1.0, 0.0]}

    payload =
      @recorded["payload"]
      |> Map.put("holdouts", [holdout])
      |> Map.update!("experiments", fn [first | rest] ->
        [Map.put(first, "holdoutIds", [99]) | rest]
      end)

    assert sessions(payload) == @recorded["sessions"]
  end

  # The placeholder of a read while absent re-resolves only covered
  # assignments at set_unit: an uncovered split rule installed by set_data/2
  # after that read keeps main's result once its unit is set. (The
  # JavaScript SDK returns 1 here; this PR keeps main's behaviour.)
  test "set_unit after a placeholder keeps main's result for an uncovered rule" do
    rules =
      Jason.encode!(%{
        "rules" => [
          %{
            "name" => "All",
            "type" => "split",
            "conditions" => nil,
            "environments" => [],
            "percentages" => "0/100"
          }
        ]
      })

    experiment = %{
      "id" => 1,
      "name" => "exp_rule",
      "iteration" => 1,
      "unitType" => "session_id",
      "seedHi" => 1,
      "seedLo" => 2,
      "split" => [0.5, 0.5],
      "trafficSeedHi" => 3,
      "trafficSeedLo" => 4,
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => 0,
      "applications" => [],
      "variants" => [%{"name" => "A", "config" => nil}, %{"name" => "B", "config" => nil}],
      "audience" => nil,
      "audienceStrict" => false,
      "assignmentRules" => rules
    }

    sdk_config = %Types.SDKConfig{
      endpoint: Base.encode64(:erlang.term_to_binary(self())),
      api_key: "k",
      application: "website",
      environment: "production",
      publisher: Publisher
    }

    {:ok, ctx} =
      Context.start_link(sdk_config, %Types.ContextData{experiments: []}, %Types.ContextConfig{
        units: %{}
      })

    assert Context.treatment(ctx, "exp_rule") == 0
    :ok = Context.set_data(ctx, %{"experiments" => [experiment]})
    assert Context.peek(ctx, "exp_rule") == 0
    :ok = Context.set_unit(ctx, "session_id", "e791e240fcd3df7d238cfc285f475e8152fcc0ec")
    assert Context.treatment(ctx, "exp_rule") == 0
  end
end
