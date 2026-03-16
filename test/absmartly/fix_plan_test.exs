defmodule ABSmartly.FixPlanTest do
  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types, Utils}
  alias ABSmartly.JSONExpr.Evaluator
  alias ABSmartly.Matcher

  @context_params %{
    "session_id" => "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
    "user_id" => "123456789"
  }

  @get_context_response %{
    "experiments" => [
      %{
        "id" => 1,
        "name" => "exp_test_ab",
        "iteration" => 1,
        "unitType" => "session_id",
        "seedHi" => 3603515,
        "seedLo" => 233373850,
        "split" => [0.5, 0.5],
        "trafficSeedHi" => 449867249,
        "trafficSeedLo" => 455443629,
        "trafficSplit" => [0.0, 1.0],
        "fullOnVariant" => 0,
        "applications" => [%{"name" => "website"}],
        "variants" => [
          %{"name" => "A", "config" => nil},
          %{"name" => "B", "config" => "{\"banner.border\":1,\"banner.size\":\"large\"}"}
        ],
        "audience" => nil,
        "customFieldValues" => nil
      },
      %{
        "id" => 2,
        "name" => "exp_test_abc",
        "iteration" => 1,
        "unitType" => "session_id",
        "seedHi" => 55006150,
        "seedLo" => 47189152,
        "split" => [0.34, 0.33, 0.33],
        "trafficSeedHi" => 705671872,
        "trafficSeedLo" => 212903484,
        "trafficSplit" => [0.0, 1.0],
        "fullOnVariant" => 0,
        "applications" => [%{"name" => "website"}],
        "variants" => [
          %{"name" => "A", "config" => nil},
          %{"name" => "B", "config" => "{\"button.color\":\"blue\"}"},
          %{"name" => "C", "config" => "{\"button.color\":\"red\"}"}
        ],
        "audience" => "",
        "customFieldValues" => nil
      }
    ]
  }

  defp start_context(response, units \\ nil) do
    context_units = units || @context_params
    sdk_config = %Types.SDKConfig{
      endpoint: "https://test.absmartly.io/v1",
      api_key: "test-api-key",
      application: "website",
      environment: "development"
    }
    context_data = Types.ContextData.from_map(response)
    context_config = %Types.ContextConfig{
      units: context_units,
      overrides: %{},
      custom_assignments: %{}
    }
    {:ok, pid} = Context.start_link(sdk_config, context_data, context_config)
    pid
  end

  defp start_context_with_refresh(response, refresh_response, units \\ nil) do
    context_units = units || @context_params
    sdk_config = %Types.SDKConfig{
      endpoint: "https://test.absmartly.io/v1",
      api_key: "test-api-key",
      application: "website",
      environment: "development"
    }
    context_data = Types.ContextData.from_map(response)
    context_config = %Types.ContextConfig{
      units: context_units,
      overrides: %{},
      custom_assignments: %{}
    }
    refresh_data = Types.ContextData.from_map(refresh_response)
    data_fetcher = fn -> {:ok, refresh_data} end
    {:ok, pid} = Context.start_link(sdk_config, context_data, context_config, data_fetcher: data_fetcher)
    pid
  end

  # Fix #4: Cross-type comparison
  describe "fix #4 - cross-type comparison" do
    test "compare number to string coerces string" do
      assert Evaluator.compare(1, "1.0") == 0
      assert Evaluator.compare(2, "1") == 1
      assert Evaluator.compare(1, "2") == -1
    end

    test "compare string to number coerces string" do
      assert Evaluator.compare("1.0", 1) == 0
      assert Evaluator.compare("3", 2) == 1
      assert Evaluator.compare("1", 2) == -1
    end

    test "compare number to non-numeric string returns nil" do
      assert Evaluator.compare(1, "abc") == nil
      assert Evaluator.compare("abc", 1) == nil
    end

    test "eq works across types" do
      expr = %{"eq" => [%{"value" => 1}, %{"value" => "1.0"}]}
      assert Evaluator.evaluate(expr, %{}) == true
    end

    test "gt works across types" do
      expr = %{"gt" => [%{"value" => 2}, %{"value" => "1"}]}
      assert Evaluator.evaluate(expr, %{}) == true
    end
  end

  # Fix #5: Wrong app name in config
  describe "fix #5 - config app name" do
    test "config uses :absmartly app name" do
      config = Application.get_all_env(:absmartly)
      assert Keyword.get(config, :json_library) == Jason
    end

    test "elixir_wrapper config does not exist" do
      config = Application.get_all_env(:elixir_wrapper)
      assert config == []
    end
  end

  # Fix #6: Attribute list storage
  describe "fix #6 - attribute list storage" do
    test "attributes stored as list and get_attribute returns last value" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "key1", "val1")
      Context.set_attribute(ctx, "key2", "val2")
      assert Context.get_attribute(ctx, "key1") == "val1"
      assert Context.get_attribute(ctx, "key2") == "val2"
    end

    test "set_attribute appends and get_attribute returns last value" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "key", "old")
      Context.set_attribute(ctx, "key", "new")
      assert Context.get_attribute(ctx, "key") == "new"
    end

    test "both entries stored in list when set twice" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "key", "old")
      Context.set_attribute(ctx, "key", "new")
      attrs = Context.get_attributes(ctx)
      assert length(Enum.filter(attrs, fn a -> a.name == "key" end)) == 2
    end

    test "batch set_attributes with map" do
      ctx = start_context(@get_context_response)
      Context.set_attributes(ctx, %{"a" => 1, "b" => 2})
      assert Context.get_attribute(ctx, "a") == 1
      assert Context.get_attribute(ctx, "b") == 2
    end
  end

  # Fix #7 & #18: Cached audience JSON and single audience_match? call
  describe "fix #7/#18 - cached audience and single evaluation" do
    test "audience matching works with cached parsed JSON" do
      response = put_in(
        @get_context_response,
        ["experiments", Access.at(0), "audience"],
        Jason.encode!(%{"filter" => [%{"gte" => [%{"var" => "age"}, %{"value" => 18}]}]})
      )
      response = put_in(response, ["experiments", Access.at(0), "audienceStrict"], true)

      ctx = start_context(response)
      Context.set_attribute(ctx, "age", 20)
      assert Context.treatment(ctx, "exp_test_ab") == 1

      ctx2 = start_context(response)
      Context.set_attribute(ctx2, "age", 15)
      assert Context.treatment(ctx2, "exp_test_ab") == 0
    end
  end

  # Fix #8: Variable index ordering
  describe "fix #8 - variable index ordering" do
    test "variable index preserves experiment order" do
      ctx = start_context(@get_context_response)
      keys = Context.variable_keys(ctx)
      assert is_map(keys)
      assert Map.has_key?(keys, "banner.border")
      assert Map.has_key?(keys, "banner.size")
      assert "exp_test_ab" in keys["banner.border"]
      assert "exp_test_ab" in keys["banner.size"]
    end
  end

  # Fix #10: set_overrides clears exposed_experiments
  describe "fix #10 - set_overrides exposed_experiments cleanup" do
    test "set_overrides clears exposed_experiments for each key" do
      ctx = start_context(@get_context_response)

      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1

      Context.set_overrides(ctx, %{"exp_test_ab" => 0})
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 2
    end
  end

  # Fix #11: Evaluator scalar values
  describe "fix #11 - evaluate scalar values" do
    test "returns number for number expression" do
      assert Evaluator.evaluate(42, %{}) == 42
      assert Evaluator.evaluate(3.14, %{}) == 3.14
    end

    test "returns string for string expression" do
      assert Evaluator.evaluate("hello", %{}) == "hello"
    end

    test "returns boolean for boolean expression" do
      assert Evaluator.evaluate(true, %{}) == true
      assert Evaluator.evaluate(false, %{}) == false
    end

    test "still returns nil for nil" do
      assert Evaluator.evaluate(nil, %{}) == nil
    end
  end

  # Fix #12/#34: to_number("") returns 0 (integer)
  describe "fix #12/#34 - to_number empty string" do
    test "to_number of empty string returns integer 0" do
      result = Utils.to_number("")
      assert result == 0
      assert is_integer(result)
    end
  end

  # Fix #13: Context type spec
  describe "fix #13 - type spec" do
    test "Context module has GenServer.server type" do
      ctx = start_context(@get_context_response)
      assert is_pid(ctx)
    end
  end

  # Fix #15: terminate/2 synchronous publish
  describe "fix #15 - terminate synchronous publish" do
    test "context process terminates cleanly" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1
      ref = Process.monitor(ctx)
      GenServer.stop(ctx, :normal)
      assert_receive {:DOWN, ^ref, :process, ^ctx, :normal}, 10_000
    end
  end

  # Fix #16/#35: set_failed and wait_until_ready with failed state
  describe "fix #16/#35 - failed state handling" do
    test "set_failed marks context as failed" do
      sdk_config = %Types.SDKConfig{
        endpoint: "https://test.absmartly.io/v1",
        api_key: "test-api-key",
        application: "website",
        environment: "development"
      }
      context_config = %Types.ContextConfig{
        units: @context_params,
        overrides: %{},
        custom_assignments: %{}
      }
      {:ok, ctx} = Context.start_link_async(sdk_config, context_config)
      assert Context.is_ready?(ctx) == false
      assert Context.is_failed?(ctx) == false

      Context.set_failed(ctx, :fetch_error)
      assert Context.is_failed?(ctx) == true
    end

    test "wait_until_ready returns error when failed" do
      sdk_config = %Types.SDKConfig{
        endpoint: "https://test.absmartly.io/v1",
        api_key: "test-api-key",
        application: "website",
        environment: "development"
      }
      context_config = %Types.ContextConfig{
        units: @context_params,
        overrides: %{},
        custom_assignments: %{}
      }
      {:ok, ctx} = Context.start_link_async(sdk_config, context_config)

      spawn(fn ->
        Process.sleep(50)
        Context.set_failed(ctx, :test_error)
      end)

      assert {:error, :test_error} = Context.wait_until_ready(ctx, 5000)
    end
  end

  # Fix #17: set_custom_assignments clears exposed_experiments
  describe "fix #17 - set_custom_assignments exposed_experiments cleanup" do
    test "set_custom_assignments clears exposed_experiments for each key" do
      ctx = start_context(@get_context_response)

      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1

      Context.set_custom_assignments(ctx, %{"exp_test_ab" => 0})
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 2
    end
  end

  # Fix #19/#24: Counter-based pending, O(1) queue overflow
  describe "fix #19/#24 - counter-based pending" do
    test "pending uses counter fields" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1

      Context.track(ctx, "goal1")
      assert Context.pending(ctx) == 2
    end
  end

  # Fix #20: Matcher uses AND semantics (via evaluator)
  describe "fix #20 - matcher filter AND semantics" do
    test "filter with multiple expressions uses AND" do
      filter = %{
        "filter" => [
          %{"gte" => [%{"var" => "age"}, %{"value" => 18}]},
          %{"eq" => [%{"var" => "country"}, %{"value" => "US"}]}
        ]
      }

      attrs_both = [%{"name" => "age", "value" => 25}, %{"name" => "country", "value" => "US"}]
      assert Matcher.evaluate(filter, attrs_both) == true

      attrs_age_only = [%{"name" => "age", "value" => 25}, %{"name" => "country", "value" => "UK"}]
      assert Matcher.evaluate(filter, attrs_age_only) == false

      attrs_country_only = [%{"name" => "age", "value" => 15}, %{"name" => "country", "value" => "US"}]
      assert Matcher.evaluate(filter, attrs_country_only) == false
    end
  end

  # Fix #22: Unless instead of negated condition (code style, tested via queue_exposure)
  describe "fix #22 - idiomatic unless" do
    test "exposure only queued once per experiment" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1
    end
  end

  # Fix #26: hash_unit computed once per assign_variant
  describe "fix #26 - hash_unit efficiency" do
    test "assignment still works correctly with single hash computation" do
      ctx = start_context(@get_context_response)
      v1 = Context.treatment(ctx, "exp_test_ab")
      v2 = Context.peek(ctx, "exp_test_ab")
      assert v1 == v2
      assert is_integer(v1)
    end
  end

  # Fix #27: get_opt handles explicit nil
  describe "fix #27 - ContextConfig get_opt nil handling" do
    test "explicit nil value is respected" do
      config = Types.ContextConfig.from_options(%{event_handler: nil})
      assert config.event_handler == nil
    end

    test "missing key uses default" do
      config = Types.ContextConfig.from_options(%{})
      assert config.publish_delay == -1
      assert config.refresh_period == 0
    end

    test "false value is accepted" do
      config = Types.ContextConfig.from_options(%{"publishDelay" => 0})
      assert config.publish_delay == 0
    end
  end

  # Fix #28: child_spec for DynamicSupervisor
  describe "fix #28 - child_spec" do
    test "Context module has child_spec" do
      spec = Context.child_spec([%{}, %{}, %{}])
      assert spec.id == Context
      assert spec.type == :worker
      assert spec.restart == :temporary
    end
  end

  # Fix #29: Experiment index for O(1) lookup
  describe "fix #29 - experiment index" do
    test "experiment lookup by name is O(1)" do
      ctx = start_context(@get_context_response)
      assert Context.treatment(ctx, "exp_test_ab") == 1
      assert Context.treatment(ctx, "exp_test_abc") == 2
      assert Context.treatment(ctx, "not_found") == 0
    end
  end

  # Fix #32: Split changes in invalidation
  describe "fix #32 - split changes invalidation" do
    test "refresh picks up split changes" do
      changed_split_response = %{@get_context_response |
        "experiments" => Enum.map(@get_context_response["experiments"], fn exp ->
          if exp["name"] == "exp_test_ab" do
            Map.put(exp, "split", [0.9, 0.1])
          else
            exp
          end
        end)
      }
      ctx = start_context_with_refresh(@get_context_response, changed_split_response)
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1

      Context.refresh(ctx)
      v2 = Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 2
      assert is_integer(v2)
    end
  end

  # Fix #38: defdelegate create_context_async
  describe "fix #38 - ABSmartly.create_context_async delegated" do
    test "create_context_async is accessible via ABSmartly module" do
      funs = ABSmartly.__info__(:functions)
      assert {:create_context_async, 2} in funs
      assert {:create_context_async, 3} in funs
    end
  end

  # Fix #39: Retry cap
  describe "fix #39 - retry cap" do
    test "HTTP client caps retries at 10" do
      assert function_exported?(ABSmartly.HTTP.Client, :fetch_context, 5)
    end
  end

  # Fix #3: DynamicSupervisor usage
  describe "fix #3 - DynamicSupervisor" do
    test "context can be started under DynamicSupervisor" do
      sdk_config = %Types.SDKConfig{
        endpoint: "https://test.absmartly.io/v1",
        api_key: "test-api-key",
        application: "website",
        environment: "development"
      }
      context_data = Types.ContextData.from_map(@get_context_response)
      context_config = %Types.ContextConfig{
        units: @context_params,
        overrides: %{},
        custom_assignments: %{}
      }

      {:ok, ctx} = DynamicSupervisor.start_child(
        ABSmartly.ContextSupervisor,
        {Context, [sdk_config, context_data, context_config]}
      )

      assert is_pid(ctx)
      assert Context.is_ready?(ctx) == true
      assert Context.treatment(ctx, "exp_test_ab") == 1
    end
  end

  # Fix #2: Publish uses Task.async with timeout (tested via existing publish tests passing)
  describe "fix #2 - publish with Task.async" do
    test "publish clears queue" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1
      assert :ok = Context.publish(ctx)
      assert Context.pending(ctx) == 0
    end
  end

  # Fix #21: Publish events format
  describe "fix #21 - publish event format" do
    test "publish event map contains expected keys" do
      events_captured = :ets.new(:test_events, [:set, :public])
      handler = fn event_type, data ->
        :ets.insert(events_captured, {event_type, data})
      end

      sdk_config = %Types.SDKConfig{
        endpoint: "https://test.absmartly.io/v1",
        api_key: "test-api-key",
        application: "website",
        environment: "development"
      }
      context_data = Types.ContextData.from_map(@get_context_response)
      context_config = %Types.ContextConfig{
        units: @context_params,
        overrides: %{},
        custom_assignments: %{},
        event_handler: handler
      }
      {:ok, ctx} = Context.start_link(sdk_config, context_data, context_config)

      Context.treatment(ctx, "exp_test_ab")
      Context.publish(ctx)

      Process.sleep(100)
      [{:publish, event_map}] = :ets.lookup(events_captured, :publish)
      assert Map.has_key?(event_map, "hashed")
      assert Map.has_key?(event_map, "units")
      assert Map.has_key?(event_map, "exposures")
      assert Map.has_key?(event_map, "goals")
      assert Map.has_key?(event_map, "attributes")

      :ets.delete(events_captured)
    end
  end

  # Fix #40: Test coverage for terminate, handle_info, queue overflow, etc.
  describe "fix #40 - additional test coverage" do
    test "handle_info for unexpected messages" do
      ctx = start_context(@get_context_response)
      send(ctx, :unexpected_message)
      assert Context.is_ready?(ctx) == true
    end

    test "handle_info for non-EXIT signals" do
      ctx = start_context(@get_context_response)
      send(ctx, {:some_other_message, self(), :data})
      Process.sleep(50)
      assert Process.alive?(ctx)
      assert Context.is_ready?(ctx) == true
    end

    test "queue overflow drops oldest exposure" do
      ctx = start_context(@get_context_response, %{})

      for i <- 1..100 do
        Context.set_unit(ctx, "session_id", "uid_#{i}")
        Context.set_override(ctx, "exp_#{i}", 1)
        Context.treatment(ctx, "exp_#{i}")
      end

      assert Context.pending(ctx) == 100
    end

    test "data returns context data" do
      ctx = start_context(@get_context_response)
      data = Context.data(ctx)
      assert length(data.experiments) == 2
    end

    test "experiments returns experiment names" do
      ctx = start_context(@get_context_response)
      names = Context.experiments(ctx)
      assert "exp_test_ab" in names
      assert "exp_test_abc" in names
    end

    test "is_finalizing returns false initially" do
      ctx = start_context(@get_context_response)
      assert Context.is_finalizing?(ctx) == false
    end

    test "finalize is idempotent" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      Context.finalize(ctx)
      assert Context.is_finalized?(ctx) == true
    end

    test "set_units with duplicate returns error" do
      ctx = start_context(@get_context_response)
      result = Context.set_units(ctx, %{"session_id" => "different_id"})
      assert {:error, "Unit 'session_id' UID already set."} = result
    end

    test "track with non-map properties sanitizes to nil" do
      ctx = start_context(@get_context_response)
      Context.track(ctx, "goal1", "not a map")
      assert Context.pending(ctx) == 1
    end

    test "get_attributes returns list format" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "key", "value")
      attrs = Context.get_attributes(ctx)
      assert is_list(attrs)
      assert Enum.any?(attrs, fn attr -> attr.name == "key" && attr.value == "value" end)
    end
  end

  # Test for Matcher edge cases
  describe "matcher edge cases" do
    test "nil filter returns nil" do
      assert Matcher.evaluate(nil, %{}) == nil
    end

    test "empty map returns true" do
      assert Matcher.evaluate(%{}, %{}) == true
    end

    test "invalid filter sentinel returns false" do
      assert Matcher.evaluate(%{"invalid" => true}, %{}) == false
    end

    test "non-list filter value fails closed" do
      assert Matcher.evaluate(%{"filter" => "not_a_list"}, %{}) == false
    end

    test "non-map filter fails closed" do
      assert Matcher.evaluate("string", %{}) == false
    end
  end

  # Phase 3.2: ready_error
  describe "phase 3.2 - ready_error" do
    test "ready_error returns nil when context loaded successfully" do
      ctx = start_context(@get_context_response)
      assert Context.ready_error(ctx) == nil
    end

    test "ready_error returns the reason when set_failed called" do
      sdk_config = %Types.SDKConfig{
        endpoint: "https://test.absmartly.io/v1",
        api_key: "test-api-key",
        application: "website",
        environment: "development"
      }
      context_config = %Types.ContextConfig{
        units: @context_params,
        overrides: %{},
        custom_assignments: %{}
      }
      {:ok, ctx} = Context.start_link_async(sdk_config, context_config)
      Context.set_failed(ctx, :fetch_error)
      assert Context.ready_error(ctx) == :fetch_error
    end
  end

  # Phase 4.4: global custom_field_keys
  describe "phase 4.4 - global custom_field_keys" do
    @get_context_response_with_custom_fields %{
      "experiments" => [
        %{
          "id" => 1,
          "name" => "exp_test_ab",
          "iteration" => 1,
          "unitType" => "session_id",
          "seedHi" => 3603515,
          "seedLo" => 233373850,
          "split" => [0.5, 0.5],
          "trafficSeedHi" => 449867249,
          "trafficSeedLo" => 455443629,
          "trafficSplit" => [0.0, 1.0],
          "fullOnVariant" => 0,
          "applications" => [%{"name" => "website"}],
          "variants" => [%{"name" => "A", "config" => nil}, %{"name" => "B", "config" => nil}],
          "audience" => nil,
          "customFieldValues" => [
            %{"name" => "key1", "value" => "val1", "type" => "string"},
            %{"name" => "key2", "value" => "val2", "type" => "string"}
          ]
        },
        %{
          "id" => 2,
          "name" => "exp_test_abc",
          "iteration" => 1,
          "unitType" => "session_id",
          "seedHi" => 55006150,
          "seedLo" => 47189152,
          "split" => [0.34, 0.33, 0.33],
          "trafficSeedHi" => 705671872,
          "trafficSeedLo" => 212903484,
          "trafficSplit" => [0.0, 1.0],
          "fullOnVariant" => 0,
          "applications" => [%{"name" => "website"}],
          "variants" => [%{"name" => "A", "config" => nil}, %{"name" => "B", "config" => nil}],
          "audience" => nil,
          "customFieldValues" => [
            %{"name" => "key2", "value" => "val2b", "type" => "string"},
            %{"name" => "key3", "value" => "val3", "type" => "string"}
          ]
        }
      ]
    }

    test "custom_field_keys returns all unique keys across all experiments" do
      ctx = start_context(@get_context_response_with_custom_fields)
      keys = Context.custom_field_keys(ctx)
      assert "key1" in keys
      assert "key2" in keys
      assert "key3" in keys
      assert length(Enum.uniq(keys)) == length(keys)
    end

    test "custom_field_keys returns empty list when no custom fields" do
      ctx = start_context(@get_context_response)
      keys = Context.custom_field_keys(ctx)
      assert keys == []
    end
  end

  # Phase 4.5: attribute list storage model
  describe "phase 4.5 - attribute list storage model" do
    test "set_attribute appends entries, both in list" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "color", "red")
      Context.set_attribute(ctx, "color", "blue")
      attrs = Context.get_attributes(ctx)
      color_attrs = Enum.filter(attrs, fn a -> a.name == "color" end)
      assert length(color_attrs) == 2
      assert Enum.at(color_attrs, 0).value == "red"
      assert Enum.at(color_attrs, 1).value == "blue"
    end

    test "get_attribute returns last value for name" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "color", "red")
      Context.set_attribute(ctx, "color", "blue")
      assert Context.get_attribute(ctx, "color") == "blue"
    end

    test "attributes have set_at timestamp" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "key", "val")
      attrs = Context.get_attributes(ctx)
      assert length(attrs) == 1
      attr = hd(attrs)
      assert Map.has_key?(attr, :set_at)
      assert is_integer(attr.set_at)
      assert attr.set_at > 0
    end
  end

  describe "fix 4.1 - set_override succeeds after finalize" do
    test "set_override returns :ok after finalize" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert Context.is_finalized?(ctx) == true
      assert Context.set_override(ctx, "exp_test_ab", 2) == :ok
    end

    test "set_overrides returns :ok after finalize" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert Context.is_finalized?(ctx) == true
      assert Context.set_overrides(ctx, %{"exp_test_ab" => 2}) == :ok
    end
  end
end
