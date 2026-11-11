defmodule ABSmartly.SystemAttributesTest do
  @moduledoc """
  Audiences and assignment-rule conditions must always see the `application`
  and `environment` names configured in the SDK, with user-set attributes
  overlaid on top. The names are never published (the collector adds them
  server-side) and `app_version` is never injected.

  Mirrors the JavaScript SDK (reference implementation) brief §4 tests 1-8,
  excluding test 5 (assignment-rule conditions), which this SDK does not
  implement.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types}

  @units %{"session_id" => "e791e240fcd3df7d238cfc285f475e8152fcc0ec"}

  defmodule CapturePublisher do
    @moduledoc false
    @behaviour ABSmartly.ContextPublisher

    def start do
      name = :"capture_publisher_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Agent.start_link(fn -> [] end, name: name)
      Atom.to_string(name)
    end

    def events(endpoint) do
      Agent.get(String.to_existing_atom(endpoint), &Enum.reverse/1)
    end

    @impl ABSmartly.ContextPublisher
    def publish(endpoint, _api_key, _application, _environment, event_map, _retries) do
      Agent.update(String.to_existing_atom(endpoint), &[event_map | &1])
      :ok
    end
  end

  # A single full-on experiment whose variant 1 is deterministic regardless of
  # the unit split, so a successful audience match yields variant 1 and a strict
  # mismatch forces variant 0.
  defp experiment(audience, opts \\ []) do
    %{
      "id" => 1,
      "name" => "exp_system",
      "iteration" => 1,
      "unitType" => "session_id",
      "seedHi" => 3_603_515,
      "seedLo" => 233_373_850,
      "split" => [0.5, 0.5],
      "trafficSeedHi" => 449_867_249,
      "trafficSeedLo" => 455_443_629,
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => Keyword.get(opts, :full_on_variant, 1),
      "applications" => [%{"name" => "website"}],
      "variants" => [
        %{"name" => "A", "config" => "{\"color\":\"a\"}"},
        %{"name" => "B", "config" => "{\"color\":\"b\"}"}
      ],
      "audienceStrict" => Keyword.get(opts, :audience_strict, true),
      "audience" => audience,
      "customFieldValues" => nil
    }
  end

  defp filter(var, value) do
    Jason.encode!(%{"filter" => [%{"eq" => [%{"var" => var}, %{"value" => value}]}]})
  end

  defp sdk_config(opts \\ []) do
    %Types.SDKConfig{
      endpoint: Keyword.get(opts, :endpoint, "https://test.absmartly.io/v1"),
      api_key: "test-api-key",
      application: Keyword.get(opts, :application, "website"),
      environment: Keyword.get(opts, :environment, "production"),
      publisher: Keyword.get(opts, :publisher, ABSmartly.Test.OkPublisher)
    }
  end

  defp context_config(opts \\ []) do
    %Types.ContextConfig{
      units: @units,
      overrides: %{},
      custom_assignments: %{},
      attributes: Keyword.get(opts, :attributes, []),
      event_handler: Keyword.get(opts, :event_handler)
    }
  end

  defp start_context(experiment, sdk_opts \\ [], cfg_opts \\ []) do
    data = Types.ContextData.from_map(%{"experiments" => [experiment]})
    {:ok, ctx} = Context.start_link(sdk_config(sdk_opts), data, context_config(cfg_opts))
    ctx
  end

  describe "system attributes in audience evaluation" do
    test "strict audience on the environment matches (regression pin)" do
      ctx = start_context(experiment(filter("environment", "production")))
      assert Context.treatment(ctx, "exp_system") == 1
    end

    test "strict audience on the application matches" do
      ctx = start_context(experiment(filter("application", "website")))
      assert Context.treatment(ctx, "exp_system") == 1
    end

    test "no match gives variant 0 with audienceMismatch true" do
      test_pid = self()
      handler = fn type, data -> send(test_pid, {:event, type, data}) end

      ctx =
        start_context(
          experiment(filter("environment", "staging")),
          [],
          event_handler: handler
        )

      assert Context.treatment(ctx, "exp_system") == 0

      assert_receive {:event, :exposure, exposure}
      assert exposure.audience_mismatch == true
    end

    test "user-set attribute overrides the system value and invalidates a cached assignment" do
      ctx = start_context(experiment(filter("environment", "production")))
      assert Context.treatment(ctx, "exp_system") == 1

      :ok = Context.set_attribute(ctx, "environment", "staging")
      assert Context.peek(ctx, "exp_system") == 0
    end

    test "a user-set attribute makes a staging filter match the overridden value" do
      ctx =
        start_context(
          experiment(filter("environment", "staging")),
          [],
          attributes: [%{"name" => "environment", "value" => "staging"}]
        )

      assert Context.treatment(ctx, "exp_system") == 1
    end

    test "missing environment config leaves the key out and a filter does not match" do
      ctx =
        start_context(
          experiment(filter("environment", "production")),
          environment: nil
        )

      assert Context.treatment(ctx, "exp_system") == 0
    end

    test "nothing extra is published (no application/environment/app_version entries)" do
      endpoint = CapturePublisher.start()

      ctx =
        start_context(
          experiment(filter("environment", "production")),
          endpoint: endpoint,
          publisher: CapturePublisher
        )

      assert Context.treatment(ctx, "exp_system") == 1
      :ok = Context.publish(ctx)

      [event_map] = CapturePublisher.events(endpoint)
      attr_names = Enum.map(event_map["attributes"] || [], & &1["name"])

      refute "application" in attr_names
      refute "environment" in attr_names
      refute "app_version" in attr_names
    end

    test "a user-set attribute is still published normally" do
      endpoint = CapturePublisher.start()

      ctx =
        start_context(
          experiment(filter("environment", "production")),
          endpoint: endpoint,
          publisher: CapturePublisher
        )

      :ok = Context.set_attribute(ctx, "user_agent", "Mozilla/5.0")
      assert Context.treatment(ctx, "exp_system") == 1
      :ok = Context.publish(ctx)

      [event_map] = CapturePublisher.events(endpoint)
      attr_names = Enum.map(event_map["attributes"] || [], & &1["name"])

      assert "user_agent" in attr_names
    end

    test "app_version is never injected, so a filter on it does not match" do
      ctx = start_context(experiment(filter("app_version", "1.0.0")))
      assert Context.treatment(ctx, "exp_system") == 0
    end

    test "system attributes are not returned by get_attributes" do
      ctx = start_context(experiment(nil))
      assert Context.get_attributes(ctx) == []
    end
  end
end
