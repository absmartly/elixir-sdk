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
      assert Context.is_ready?(ctx) == true
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

    test "SDK.create_context_async/3 starts a supervised context that reaches a terminal state" do
      {:ok, sdk} =
        ABSmartly.SDK.new(
          endpoint: "http://127.0.0.1:1",
          api_key: "k",
          application: "app",
          environment: "test",
          retries: 0,
          timeout: 500
        )

      assert {:ok, ctx} = ABSmartly.SDK.create_context_async(sdk, %{"user_id" => "u1"})
      assert is_pid(ctx)
      assert {:error, _reason} = Context.wait_until_ready(ctx, 5_000)
      assert Context.is_failed?(ctx) == true
    end

    test "SDK timeout bounds each HTTP request" do
      {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(l)
      spawn_link(fn ->
        {:ok, c} = :gen_tcp.accept(l)
        Process.sleep(2_000)
        :gen_tcp.close(c)
      end)

      t0 = System.monotonic_time(:millisecond)
      assert {:error, _} = ABSmartly.HTTP.Client.fetch_context("http://127.0.0.1:#{port}", "k", "a", "e", 0, 100)
      assert System.monotonic_time(:millisecond) - t0 < 1_000
    end

    test "dispose/1 finalizes and releases the supervised context process" do
      {:ok, sdk} =
        ABSmartly.SDK.new(endpoint: "http://127.0.0.1:1", api_key: "k", application: "app", environment: "test", retries: 0, timeout: 200)

      {:ok, ctx} = ABSmartly.SDK.create_context_async(sdk, %{"user_id" => "u1"})
      ref = Process.monitor(ctx)
      before = DynamicSupervisor.count_children(ABSmartly.ContextSupervisor).active
      assert :ok = Context.dispose(ctx)
      assert_receive {:DOWN, ^ref, :process, ^ctx, _}, 1_000
      refute Process.alive?(ctx)
      assert DynamicSupervisor.count_children(ABSmartly.ContextSupervisor).active < before
    end

    test "dispose/1 releases the process even when the final publish keeps failing" do
      defmodule FailingPublisher do
        def publish(_e, _k, _a, _env, _events, _retries), do: {:error, "collector down"}
      end

      {:ok, sdk} =
        ABSmartly.SDK.new(endpoint: "http://127.0.0.1:1", api_key: "k", application: "app", environment: "test", retries: 0, timeout: 200)

      sdk = %{sdk | config: Map.put(sdk.config, :publisher, FailingPublisher)}
      {:ok, ctx} = ABSmartly.SDK.create_context_async(sdk, %{"user_id" => "u1"})
      :ok = Context.set_data(ctx, %{"experiments" => []})
      :ok = Context.track(ctx, "goal", %{})
      ref = Process.monitor(ctx)

      assert {:error, {:disposed_unpublished, "collector down"}} =
               Context.dispose(ctx, attempts: 2, backoff: 1)

      assert_receive {:DOWN, ^ref, :process, ^ctx, _}, 1_000
    end

    test "dispose/1 is not held up by a blocking publisher at termination" do
      defmodule BlockingPublisher do
        def publish(_e, _k, _a, _env, _events, _retries), do: {:error, "first"}
      end

      {:ok, sdk} =
        ABSmartly.SDK.new(endpoint: "http://127.0.0.1:1", api_key: "k", application: "app", environment: "test", retries: 0, timeout: 50)

      sdk = %{sdk | config: Map.put(sdk.config, :publisher, BlockingPublisher)}
      {:ok, ctx} = ABSmartly.SDK.create_context_async(sdk, %{"user_id" => "u1"})
      :ok = Context.set_data(ctx, %{"experiments" => []})
      :ok = Context.track(ctx, "goal", %{})
      t0 = System.monotonic_time(:millisecond)
      assert {:error, {:disposed_unpublished, "first"}} = Context.dispose(ctx, attempts: 1)
      assert System.monotonic_time(:millisecond) - t0 < 2_000
      refute Process.alive?(ctx)
    end

    test "malformed refresh data returns an error and keeps the context alive" do
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), context_config(),
          data_fetcher: fn -> {:ok, %{"experiments" => []}} end
        )

      assert :ok = Context.wait_until_ready(ctx, 1_000)
      assert {:error, _} = Context.refresh(ctx, %{"experiments" => %{"x" => 1}})
      assert Process.alive?(ctx)
      bad = %{"experiments" => [%{"id" => 1, "name" => "e", "unitType" => "user", "split" => [0.5, 0.5], "variants" => 42}]}
      assert {:error, _} = Context.refresh(ctx, bad)
      assert Process.alive?(ctx)
      assert :ok = Context.refresh(ctx, %{"experiments" => []})
    end

    test "split with a non-list value is rejected without killing the context" do
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), context_config(),
          data_fetcher: fn -> {:ok, %{"experiments" => []}} end
        )

      assert :ok = Context.wait_until_ready(ctx, 1_000)
      bad = %{"experiments" => [%{"id" => 1, "name" => "e", "unitType" => "user", "split" => 42}]}
      assert {:error, _} = Context.refresh(ctx, bad)
      assert Process.alive?(ctx)
    end

    # D7 / JS context.ts:363-376,579-631 - a plain cached assignment is not
    # evicted by adding its unit, nor by an audience-only refresh.
    test "adding a missing unit and refreshing audience targeting keep cached assignments" do
      exp = fn aud ->
        %{"id" => 1, "name" => "e", "unitType" => "user", "iteration" => 1, "seedHi" => 1, "seedLo" => 2,
          "split" => [0, 1], "trafficSeedHi" => 3, "trafficSeedLo" => 4, "trafficSplit" => [0, 1],
          "variants" => [%{"config" => nil}, %{"config" => nil}],
          "audienceStrict" => true, "audience" => Jason.encode!(%{"filter" => [%{"value" => aud}]})}
      end

      cfg = %{context_config() | units: %{}}
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), cfg,
          data_fetcher: fn -> {:ok, %{"experiments" => [exp.(true)]}} end
        )

      assert :ok = Context.wait_until_ready(ctx, 1_000)
      assert Context.peek(ctx, "e") == 0
      assert :ok = Context.set_unit(ctx, "user", "u")
      assert Context.peek(ctx, "e") == 0
      assert :ok = Context.refresh(ctx, %{"experiments" => [exp.(false)]})
      assert Context.peek(ctx, "e") == 0
    end

    test "malformed customFieldValues is rejected without killing the context" do
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), context_config(),
          data_fetcher: fn -> {:ok, %{"experiments" => []}} end
        )

      assert :ok = Context.wait_until_ready(ctx, 1_000)
      bad = %{"experiments" => [%{"id" => 1, "name" => "e", "unitType" => "user", "split" => [0, 1], "customFieldValues" => 42}]}
      assert {:error, _} = Context.refresh(ctx, bad)
      assert Process.alive?(ctx)
      assert Context.custom_field_keys(ctx) == []
    end

    # D7 / JS context.ts:363-376,579-631: adding a unit does not evict a plain
    # assignment and audience is only re-evaluated on attribute change, so
    # neither a later unit nor an audience-only refresh recalculates it.
    test "treatments stay sticky after unit add / audience-only refresh" do
      defmodule CapturePublisher do
        def publish(_e, _k, _a, _env, events, _r) do
          send(:capture_pub, {:published, events})
          :ok
        end
      end

      exp = fn aud ->
        %{"id" => 1, "name" => "e", "unitType" => "user", "iteration" => 1, "seedHi" => 1, "seedLo" => 2,
          "split" => [0, 1], "trafficSeedHi" => 3, "trafficSeedLo" => 4, "trafficSplit" => [0, 1],
          "variants" => [%{"config" => nil}, %{"config" => nil}],
          "audienceStrict" => true, "audience" => Jason.encode!(%{"filter" => [%{"value" => aud}]})}
      end

      Process.register(self(), :capture_pub)
      cfg = %{context_config() | units: %{}}
      sdk = %{sdk_config("unused") | publisher: CapturePublisher}

      {:ok, ctx} =
        Context.start_link_async(sdk, cfg, data_fetcher: fn -> {:ok, %{"experiments" => [exp.(true)]}} end)

      assert :ok = Context.wait_until_ready(ctx, 1_000)
      assert Context.treatment(ctx, "e") == 0
      :ok = Context.set_unit(ctx, "user", "u")
      assert Context.treatment(ctx, "e") == 0
      :ok = Context.publish(ctx)
      assert_receive {:published, ev1}, 1_000
      assert [%{"name" => "e", "variant" => 0}] = ev1["exposures"]

      :ok = Context.refresh(ctx, %{"experiments" => [exp.(false)]})
      assert Context.treatment(ctx, "e") == 0
      assert Context.pending(ctx) == 0
    end

    test "json custom field with non-string value does not kill the context" do
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), context_config(),
          data_fetcher: fn -> {:ok, %{"experiments" => []}} end
        )

      assert :ok = Context.wait_until_ready(ctx, 1_000)
      data = %{"experiments" => [%{"id" => 1, "name" => "e", "unitType" => "user", "split" => [0, 1],
        "customFieldValues" => [%{"name" => "meta", "type" => "json", "value" => 42}]}]}
      assert :ok = Context.refresh(ctx, data)
      assert Context.custom_field_value(ctx, "e", "meta") == nil
      assert Process.alive?(ctx)
    end

    # D4 / JS context.ts:1323-1346 - refresh on a failed context is a no-op success
    test "refresh on a failed context is a successful no-op" do
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), context_config(),
          data_fetcher: fn -> {:error, "down"} end
        )

      assert {:error, "down"} = Context.wait_until_ready(ctx, 1_000)
      data = %{"experiments" => [%{"id" => 1, "name" => "e", "unitType" => "session_id", "iteration" => 1,
        "seedHi" => 1, "seedLo" => 2, "split" => [0, 1], "trafficSeedHi" => 3, "trafficSeedLo" => 4,
        "trafficSplit" => [0, 1], "variants" => [%{"config" => nil}, %{"config" => nil}]}]}
      assert :ok = Context.refresh(ctx, data)
      assert Context.is_failed?(ctx)
      assert Context.treatment(ctx, "e") == 0
    end

    test "unchanged set_unit keeps exposure dedup; supervisor shutdown publishes pending events" do
      defmodule ShutdownPublisher do
        def publish(_e, _k, _a, _env, events, _r) do
          send(:shutdown_pub, {:published, events})
          :ok
        end
      end

      Process.register(self(), :shutdown_pub)
      sdk = %{sdk_config("unused") | publisher: ShutdownPublisher}

      data = %{"experiments" => [%{"id" => 1, "name" => "e", "unitType" => "session_id", "iteration" => 1,
        "seedHi" => 1, "seedLo" => 2, "split" => [0, 1], "trafficSeedHi" => 3, "trafficSeedLo" => 4,
        "trafficSplit" => [0, 1], "variants" => [%{"config" => nil}, %{"config" => nil}]}]}

      spec = %{
        id: Context,
        start: {Context, :start_link_async, [sdk, context_config(), [data_fetcher: fn -> {:ok, data} end]]},
        restart: :temporary,
        shutdown: 5_000
      }

      {:ok, ctx} = DynamicSupervisor.start_child(ABSmartly.ContextSupervisor, spec)
      assert :ok = Context.wait_until_ready(ctx, 1_000)
      assert Context.treatment(ctx, "e") == 1
      :ok = Context.set_unit(ctx, "session_id", "e791e240fcd3df7d238cfc285f475e8152fcc0ec")
      assert Context.treatment(ctx, "e") == 1
      :ok = Context.track(ctx, "g", %{})
      :ok = DynamicSupervisor.terminate_child(ABSmartly.ContextSupervisor, ctx)
      assert_receive {:published, ev}, 2_000
      assert length(ev["exposures"]) == 1
      assert length(ev["goals"]) == 1
    end

    # D1 / JS context.ts:318-319,533-536 - refresh before ready is rejected;
    # readiness waiters are still released when the load completes.
    test "refresh on a loading context is rejected and waiters still resolve" do
      {:ok, ctx} =
        Context.start_link_async(sdk_config("unused"), context_config(),
          data_fetcher: fn ->
            Process.sleep(300)
            {:ok, %{"experiments" => []}}
          end
        )

      waiter = Task.async(fn -> Context.wait_until_ready(ctx, 2_000) end)
      Process.sleep(50)
      assert {:error, "ABsmartly Context is not yet ready."} = Context.refresh(ctx, %{"experiments" => []})
      assert :ok = Task.await(waiter, 3_000)
    end

    test "child_spec shutdown budget covers the publisher-aware termination deadline" do
      cfg = %{sdk_config("unused") | timeout: 50, retries: 0}
      assert Context.child_spec([cfg, %Types.ContextData{}, context_config()]).shutdown >= 7_000
      assert Context.shutdown_timeout(%{cfg | publisher: ABSmartly.DefaultContextPublisher}) >= 2_000
    end

    @tag timeout: 20_000
    test "supervisor shutdown cancels a blocking trap_exit publisher within the child budget" do
      defmodule StuckPublisher do
        def publish(_e, _k, _a, _env, _events, _r) do
          Process.flag(:trap_exit, true)
          send(:stuck_pub, {:publisher_pid, self()})
          Process.sleep(:infinity)
        end
      end

      Process.register(self(), :stuck_pub)
      sdk = %{sdk_config("unused") | publisher: StuckPublisher, timeout: 50, retries: 0}
      spec = Context.child_spec([sdk, %Types.ContextData{}, context_config()])

      {:ok, ctx} = DynamicSupervisor.start_child(ABSmartly.ContextSupervisor, spec)
      :ok = Context.track(ctx, "g", %{})
      ref = Process.monitor(ctx)
      :ok = DynamicSupervisor.terminate_child(ABSmartly.ContextSupervisor, ctx)
      assert_receive {:DOWN, ^ref, :process, ^ctx, reason}, 10_000
      assert reason == :shutdown
      assert_received {:publisher_pid, pub}
      refute Process.alive?(pub)
    end

    @tag timeout: 60_000
    test "queue overflow evicts the oldest pending exposures and goals" do
      defmodule OverflowPublisher do
        def publish(_e, _k, _a, _env, events, _r) do
          send(:overflow_pub, {:published, events})
          :ok
        end
      end

      Process.register(self(), :overflow_pub)
      sdk = %{sdk_config("unused") | publisher: OverflowPublisher}

      {:ok, ctx} =
        Context.start_link_async(sdk, context_config(), data_fetcher: fn -> {:ok, %{"experiments" => []}} end)

      assert :ok = Context.wait_until_ready(ctx, 1_000)

      for i <- 1..10_002 do
        Context.set_override(ctx, "exp_#{i}", 1)
        Context.treatment(ctx, "exp_#{i}")
        Context.track(ctx, "goal_#{i}", nil)
      end

      assert Context.pending(ctx) == 20_000
      :ok = Context.publish(ctx)
      assert_receive {:published, ev}, 30_000

      exp_names = MapSet.new(ev["exposures"], & &1["name"])
      goal_names = MapSet.new(ev["goals"], & &1["name"])
      assert MapSet.size(exp_names) == 10_000
      assert MapSet.size(goal_names) == 10_000

      for i <- [1, 2] do
        refute MapSet.member?(exp_names, "exp_#{i}")
        refute MapSet.member?(goal_names, "goal_#{i}")
      end

      for i <- [3, 10_001, 10_002] do
        assert MapSet.member?(exp_names, "exp_#{i}")
        assert MapSet.member?(goal_names, "goal_#{i}")
      end
    end

    @tag timeout: 30_000
    test "supervisor shutdown during an in-flight publish stays within the child budget" do
      defmodule InflightPublisher do
        def publish(_e, _k, _a, _env, _events, _r) do
          Process.flag(:trap_exit, true)
          send(:inflight_pub, {:publisher_pid, self()})
          Process.sleep(:infinity)
        end
      end

      Process.register(self(), :inflight_pub)
      sdk = %{sdk_config("unused") | publisher: InflightPublisher, timeout: 500, retries: 10}
      spec = Context.child_spec([sdk, %Types.ContextData{}, context_config()])
      {:ok, ctx} = DynamicSupervisor.start_child(ABSmartly.ContextSupervisor, spec)
      :ok = Context.track(ctx, "g", %{})
      ref = Process.monitor(ctx)
      spawn(fn -> Context.publish(ctx) end)
      assert_receive {:publisher_pid, pub1}, 2_000

      t0 = System.monotonic_time(:millisecond)
      :ok = DynamicSupervisor.terminate_child(ABSmartly.ContextSupervisor, ctx)
      assert_receive {:DOWN, ^ref, :process, ^ctx, reason}, 20_000
      assert reason == :shutdown
      assert System.monotonic_time(:millisecond) - t0 < spec.shutdown
      refute Process.alive?(pub1)
      # the termination publish's task must not be orphaned either
      receive do
        {:publisher_pid, pub2} -> refute Process.alive?(pub2)
      after
        0 -> :ok
      end
    end

    defp exp_map(name, unit, extra \\ %{}) do
      Map.merge(
        %{"id" => 1, "name" => name, "unitType" => unit, "iteration" => 1, "seedHi" => 1, "seedLo" => 2,
          "split" => [0, 1], "trafficSeedHi" => 3, "trafficSeedLo" => 4, "trafficSplit" => [0, 1],
          "variants" => [%{"config" => nil}, %{"config" => nil}]},
        extra
      )
    end

    defp ready_ctx(experiments, cfg \\ nil, sdk \\ nil) do
      {:ok, ctx} =
        Context.start_link_async(sdk || sdk_config("unused"), cfg || context_config(),
          data_fetcher: fn -> {:ok, %{"experiments" => experiments}} end
        )

      assert :ok = Context.wait_until_ready(ctx, 1_000)
      ctx
    end

    test "custom assignment cannot bypass strict audience exclusion" do
      aud = Jason.encode!(%{"filter" => [%{"value" => false}]})
      e = exp_map("e", "session_id", %{"audienceStrict" => true, "audience" => aud})

      ctx = ready_ctx([e])
      assert Context.peek(ctx, "e") == 0
      :ok = Context.set_custom_assignment(ctx, "e", 1)
      assert Context.peek(ctx, "e") == 0

      ctx2 = ready_ctx([e])
      :ok = Context.set_custom_assignment(ctx2, "e", 1)
      assert Context.peek(ctx2, "e") == 0
    end

    test "variable_value stops exposing candidates after the winner" do
      full = fn name, color ->
        exp_map(name, "session_id", %{"fullOnVariant" => 1, "variants" => [%{"config" => nil}, %{"config" => Jason.encode!(%{"color" => color})}]})
      end

      defmodule VarPublisher do
        def publish(_e, _k, _a, _env, events, _r) do
          send(:var_pub, {:published, events})
          :ok
        end
      end

      Process.register(self(), :var_pub)
      ctx = ready_ctx([full.("e", "red"), full.("f", "blue")], nil, %{sdk_config("unused") | publisher: VarPublisher})
      assert Context.variable_value(ctx, "color", "d") == "red"
      :ok = Context.publish(ctx)
      assert_receive {:published, ev}, 1_000
      assert Enum.map(ev["exposures"], & &1["name"]) == ["e"]
    end

    test "refreshing only the unit type recalculates and re-exposes" do
      defmodule UnitTypePublisher do
        def publish(_e, _k, _a, _env, events, _r) do
          send(:ut_pub, {:published, events})
          :ok
        end
      end

      Process.register(self(), :ut_pub)
      ctx = ready_ctx([exp_map("e", "session_id")], nil, %{sdk_config("unused") | publisher: UnitTypePublisher})
      assert Context.treatment(ctx, "e") == 1
      :ok = Context.publish(ctx)
      assert_receive {:published, _}, 1_000

      :ok = Context.refresh(ctx, %{"experiments" => [exp_map("e", "device")]})
      assert Context.treatment(ctx, "e") == 0
      :ok = Context.publish(ctx)
      assert_receive {:published, ev}, 1_000
      assert [%{"name" => "e", "assigned" => false}] = Enum.map(ev["exposures"], &Map.take(&1, ["name", "assigned"]))
    end

    @tag timeout: 30_000
    test "supervisor shutdown during an in-flight refresh stays within the child budget" do
      defmodule RefreshPublisher do
        def publish(_e, _k, _a, _env, events, _r) do
          send(:rf_pub, {:published, events})
          :ok
        end
      end

      Process.register(self(), :rf_pub)
      sdk = %{sdk_config("unused") | publisher: RefreshPublisher, endpoint: "http://127.0.0.1:1", timeout: 50, retries: 10}
      spec = Context.child_spec([sdk, %Types.ContextData{}, context_config()])
      {:ok, ctx} = DynamicSupervisor.start_child(ABSmartly.ContextSupervisor, spec)
      :ok = Context.track(ctx, "g", %{})
      ref = Process.monitor(ctx)
      spawn(fn -> catch_exit(Context.refresh(ctx)) end)
      Process.sleep(200)

      t0 = System.monotonic_time(:millisecond)
      :ok = DynamicSupervisor.terminate_child(ABSmartly.ContextSupervisor, ctx)
      assert_receive {:DOWN, ^ref, :process, ^ctx, :shutdown}, 20_000
      assert System.monotonic_time(:millisecond) - t0 < spec.shutdown
      assert_received {:published, ev}
      assert length(ev["goals"]) == 1
    end

    test "a redirected event upload is not acknowledged and keeps events queued" do
      {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(l)
      parent = self()

      acceptor =
        spawn_link(fn ->
          loop = fn loop ->
            case :gen_tcp.accept(l, 10_000) do
              {:ok, c} ->
                {:ok, req} = :gen_tcp.recv(c, 0, 5_000)
                send(parent, {:request, hd(String.split(req, " "))})
                :gen_tcp.send(c, "HTTP/1.1 301 Moved Permanently\r\nlocation: /canonical/context\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
                :gen_tcp.close(c)
                loop.(loop)

              _ ->
                :ok
            end
          end

          loop.(loop)
        end)

      sdk = %{sdk_config("unused") | endpoint: "http://127.0.0.1:#{port}", retries: 0, timeout: 2_000, publisher: ABSmartly.DefaultContextPublisher}
      {:ok, ctx} = Context.start_link_async(sdk, context_config(), data_fetcher: fn -> {:ok, %{"experiments" => []}} end)
      assert :ok = Context.wait_until_ready(ctx, 1_000)
      :ok = Context.track(ctx, "g", %{})
      assert {:error, _} = Context.publish(ctx)
      assert Context.pending(ctx) == 1
      assert_receive {:request, "PUT"}, 5_000
      refute_receive {:request, "GET"}, 300
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
    end

    @tag timeout: 30_000
    test "SDK requests bypass an exhausted default hackney pool" do
      {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(l)

      acceptor =
        spawn_link(fn ->
          loop = fn loop ->
            case :gen_tcp.accept(l, 20_000) do
              {:ok, c} ->
                spawn(fn ->
                  _ = :gen_tcp.recv(c, 0, 5_000)
                  body = ~s({"experiments":[]})
                  :gen_tcp.send(c, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}")
                  :gen_tcp.close(c)
                end)

                loop.(loop)

              _ ->
                :ok
            end
          end

          loop.(loop)
        end)

      # Occupy every default-pool per-host slot with a request that never completes.
      hog_url = "http://127.0.0.1:#{port}/hog"

      {:ok, hog_listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
      {:ok, hog_port} = :inet.port(hog_listen)
      _ = hog_url

      hogs =
        for _ <- 1..60 do
          spawn(fn -> HTTPoison.get("http://127.0.0.1:#{hog_port}/x", [], recv_timeout: 20_000) end)
        end

      Process.sleep(500)

      # SDK fetch to the responsive server on the same host must still work.
      assert {:ok, %{"experiments" => []}} =
               ABSmartly.HTTP.Client.fetch_context("http://127.0.0.1:#{port}", "k", "a", "e", 0, 1_000)

      Enum.each(hogs, &Process.exit(&1, :kill))
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
    end
  end
end
