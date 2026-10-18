defmodule ABSmartly.FailureSemanticsTest do
  @moduledoc """
  A failed publish must not lose pending events, and a failed load must be
  reported through the `:error` event.

  Cross-SDK scenarios: 193 (publish failure keeps pending events) and 200
  (a failed context load emits an `error` event).
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types}
  alias ABSmartly.Test.ScriptedPublisher

  @units %{"session_id" => "e791e240fcd3df7d238cfc285f475e8152fcc0ec"}

  @context_data %{
    "experiments" => [
      %{
        "id" => 1,
        "name" => "exp_test_ab",
        "iteration" => 1,
        "unitType" => "session_id",
        "seedHi" => 3_603_515,
        "seedLo" => 233_373_850,
        "split" => [0.5, 0.5],
        "trafficSeedHi" => 449_867_249,
        "trafficSeedLo" => 455_443_629,
        "trafficSplit" => [0.0, 1.0],
        "fullOnVariant" => 0,
        "applications" => [%{"name" => "website"}],
        "variants" => [
          %{"name" => "A", "config" => nil},
          %{"name" => "B", "config" => nil}
        ],
        "audience" => nil,
        "customFieldValues" => nil
      }
    ]
  }

  defp event_recorder do
    test_pid = self()
    fn type, data -> send(test_pid, {:context_event, type, data}) end
  end

  defp sdk_config(endpoint) do
    %Types.SDKConfig{
      endpoint: endpoint,
      api_key: "test-api-key",
      application: "website",
      environment: "development",
      publisher: ScriptedPublisher
    }
  end

  defp context_config do
    %Types.ContextConfig{
      units: @units,
      overrides: %{},
      custom_assignments: %{},
      event_handler: event_recorder()
    }
  end

  defp start_context(publisher_script) do
    endpoint = ScriptedPublisher.start(publisher_script)
    data = Types.ContextData.from_map(@context_data)
    {:ok, ctx} = Context.start_link(sdk_config(endpoint), data, context_config())
    assert_received {:context_event, :ready, _}
    {ctx, endpoint}
  end

  defp exposure_names(event_map), do: Enum.map(event_map["exposures"], & &1["name"])

  describe "publish/1 when the publisher fails" do
    test "returns the publisher error and keeps the pending events" do
      {ctx, _endpoint} = start_context([{:error, "Publish failed"}])

      assert Context.treatment(ctx, "exp_test_ab") == 1
      assert Context.pending(ctx) == 1

      assert {:error, "Publish failed"} = Context.publish(ctx)
      assert Context.pending(ctx) == 1
    end

    test "emits an :error event and no :publish event" do
      {ctx, _endpoint} = start_context([{:error, "Publish failed"}])
      Context.treatment(ctx, "exp_test_ab")
      assert_received {:context_event, :exposure, _}

      assert {:error, "Publish failed"} = Context.publish(ctx)

      assert_received {:context_event, :error, "Publish failed"}
      refute_received {:context_event, :publish, _}
    end

    test "a later publish sends the kept events and then clears them" do
      {ctx, endpoint} = start_context([{:error, "Publish failed"}, :ok])
      Context.treatment(ctx, "exp_test_ab")
      Context.track(ctx, "purchase", %{"amount" => 10})
      assert Context.pending(ctx) == 2

      assert {:error, "Publish failed"} = Context.publish(ctx)
      assert Context.pending(ctx) == 2

      assert :ok = Context.publish(ctx)
      assert Context.pending(ctx) == 0

      assert [failed, published] = ScriptedPublisher.attempts(endpoint)
      assert exposure_names(failed) == ["exp_test_ab"]
      assert exposure_names(published) == ["exp_test_ab"]
      assert Enum.map(published["goals"], & &1["name"]) == ["purchase"]

      assert_received {:context_event, :publish, event_map}
      assert exposure_names(event_map) == ["exp_test_ab"]
    end

    test "a raising publisher is reported as an error and does not crash the context" do
      {ctx, _endpoint} = start_context([{:raise, "connection reset"}])
      Context.treatment(ctx, "exp_test_ab")

      assert {:error, "connection reset"} = Context.publish(ctx)
      assert Process.alive?(ctx)
      assert Context.pending(ctx) == 1
      assert_received {:context_event, :error, "connection reset"}
    end
  end

  describe "publish/1 when the publisher succeeds" do
    test "emits :publish only after the publisher accepts the events" do
      {ctx, endpoint} = start_context([:ok])
      Context.treatment(ctx, "exp_test_ab")

      assert :ok = Context.publish(ctx)
      assert Context.pending(ctx) == 0
      assert [_attempt] = ScriptedPublisher.attempts(endpoint)
      assert_received {:context_event, :publish, _}
      refute_received {:context_event, :error, _}
    end

    test "does not call the publisher when nothing is pending" do
      {ctx, endpoint} = start_context([])

      assert :ok = Context.publish(ctx)
      assert ScriptedPublisher.attempts(endpoint) == []
      refute_received {:context_event, :publish, _}
    end
  end

  describe "finalize/1 when the publisher fails" do
    test "returns the error, keeps the events and leaves the context open" do
      {ctx, _endpoint} = start_context([{:error, "Publish failed"}])
      Context.treatment(ctx, "exp_test_ab")

      assert {:error, "Publish failed"} = Context.finalize(ctx)
      assert Context.is_finalized?(ctx) == false
      assert Context.is_finalizing?(ctx) == false
      assert Context.pending(ctx) == 1
      assert_received {:context_event, :error, "Publish failed"}
      refute_received {:context_event, :finalize, _}
    end

    test "a later finalize publishes the kept events and seals the context" do
      {ctx, endpoint} = start_context([{:error, "Publish failed"}, :ok])
      Context.treatment(ctx, "exp_test_ab")

      assert {:error, "Publish failed"} = Context.finalize(ctx)
      assert :ok = Context.finalize(ctx)

      assert Context.is_finalized?(ctx) == true
      assert Context.pending(ctx) == 0
      assert [_failed, published] = ScriptedPublisher.attempts(endpoint)
      assert exposure_names(published) == ["exp_test_ab"]
      assert_received {:context_event, :finalize, nil}
    end
  end

  describe "failed context load" do
    test "a failing data_fetcher emits one :error event with the reason" do
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), context_config(),
          data_fetcher: fn -> {:error, "Context load failed"} end
        )

      assert {:error, "Context load failed"} = Context.wait_until_ready(ctx, 1_000)
      assert Context.is_failed?(ctx) == true
      assert Context.is_ready?(ctx) == false
      assert Context.ready_error(ctx) == "Context load failed"

      assert_received {:context_event, :error, "Context load failed"}
      refute_received {:context_event, :error, _}
      refute_received {:context_event, :ready, _}
    end

    test "set_failed/2 emits an :error event with the reason" do
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), context_config(),
          data_fetcher: fn ->
            Process.sleep(1_000)
            {:error, "late fetch result"}
          end
        )

      assert :ok = Context.set_failed(ctx, :fetch_error)
      assert Context.is_failed?(ctx) == true
      assert Context.ready_error(ctx) == :fetch_error
      assert_received {:context_event, :error, :fetch_error}
    end
  end
end
