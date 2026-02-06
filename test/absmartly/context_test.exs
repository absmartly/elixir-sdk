defmodule ABSmartly.ContextTest do
  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types}

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
        "customFieldValues" => [
          %{"name" => "country", "value" => "US,PT,ES,DE,FR", "type" => "string"},
          %{"name" => "json_object", "value" => "{\"123\":1,\"456\":0}", "type" => "json"},
          %{"name" => "json_array", "value" => "[\"hello\", \"world\"]", "type" => "json"},
          %{"name" => "json_number", "value" => "123", "type" => "json"},
          %{"name" => "json_string", "value" => "\"hello\"", "type" => "json"},
          %{"name" => "json_boolean", "value" => "true", "type" => "json"},
          %{"name" => "json_null", "value" => "null", "type" => "json"},
          %{"name" => "json_invalid", "value" => "invalid", "type" => "json"}
        ]
      },
      %{
        "id" => 3,
        "name" => "exp_test_not_eligible",
        "iteration" => 1,
        "unitType" => "user_id",
        "seedHi" => 503266407,
        "seedLo" => 144942754,
        "split" => [0.34, 0.33, 0.33],
        "trafficSeedHi" => 87768905,
        "trafficSeedLo" => 511357582,
        "trafficSplit" => [0.99, 0.01],
        "fullOnVariant" => 0,
        "applications" => [%{"name" => "website"}],
        "variants" => [
          %{"name" => "A", "config" => nil},
          %{"name" => "B", "config" => "{\"card.width\":\"80%\"}"},
          %{"name" => "C", "config" => "{\"card.width\":\"75%\"}"}
        ],
        "audience" => "{}",
        "customFieldValues" => nil
      },
      %{
        "id" => 4,
        "name" => "exp_test_fullon",
        "iteration" => 1,
        "unitType" => "session_id",
        "seedHi" => 856061641,
        "seedLo" => 990838475,
        "split" => [0.25, 0.25, 0.25, 0.25],
        "trafficSeedHi" => 360868579,
        "trafficSeedLo" => 330937933,
        "trafficSplit" => [0.0, 1.0],
        "fullOnVariant" => 2,
        "applications" => [%{"name" => "website"}],
        "variants" => [
          %{"name" => "A", "config" => nil},
          %{"name" => "B", "config" => "{\"submit.color\":\"red\",\"submit.shape\":\"circle\"}"},
          %{"name" => "C", "config" => "{\"submit.color\":\"blue\",\"submit.shape\":\"rect\"}"},
          %{"name" => "D", "config" => "{\"submit.color\":\"green\",\"submit.shape\":\"square\"}"}
        ],
        "audience" => "null",
        "customFieldValues" => nil
      },
      %{
        "id" => 5,
        "name" => "exp_test_custom_fields",
        "iteration" => 1,
        "unitType" => "session_id",
        "seedHi" => 9372617,
        "seedLo" => 121364805,
        "split" => [0.5, 0.5],
        "trafficSeedHi" => 318746944,
        "trafficSeedLo" => 359812364,
        "trafficSplit" => [0.0, 1.0],
        "fullOnVariant" => 0,
        "applications" => [%{"name" => "website"}],
        "variants" => [
          %{"name" => "A", "config" => nil},
          %{"name" => "B", "config" => "{\"submit.size\":\"sm\"}"}
        ],
        "audience" => nil,
        "customFieldValues" => [
          %{"name" => "country", "value" => "US,PT,ES", "type" => "string"},
          %{"name" => "languages", "value" => "en-US,en-GB,pt-PT,pt-BR,es-ES,es-MX", "type" => "string"},
          %{"name" => "text_field", "value" => "hello text", "type" => "text"},
          %{"name" => "string_field", "value" => "hello string", "type" => "string"},
          %{"name" => "number_field", "value" => "123", "type" => "number"},
          %{"name" => "boolean_field", "value" => "true", "type" => "boolean"},
          %{"name" => "false_boolean_field", "value" => "false", "type" => "boolean"},
          %{"name" => "invalid_type_field", "value" => "invalid", "type" => "invalid"}
        ]
      }
    ]
  }

  @expected_variants %{
    "exp_test_ab" => 1,
    "exp_test_abc" => 2,
    "exp_test_not_eligible" => 0,
    "exp_test_fullon" => 2,
    "exp_test_custom_fields" => 1
  }

  @expected_variables %{
    "banner.border" => 1,
    "banner.size" => "large",
    "button.color" => "red",
    "submit.color" => "blue",
    "submit.shape" => "rect",
    "submit.size" => "sm"
  }

  @refresh_context_response %{
    "experiments" => [
      %{
        "id" => 6,
        "name" => "exp_test_new",
        "iteration" => 2,
        "unitType" => "session_id",
        "seedHi" => 934590467,
        "seedLo" => 714771373,
        "split" => [0.5, 0.5],
        "trafficSeedHi" => 940553836,
        "trafficSeedLo" => 270705624,
        "trafficSplit" => [0.0, 1.0],
        "fullOnVariant" => 1,
        "applications" => [%{"name" => "website"}],
        "variants" => [
          %{"name" => "A", "config" => nil},
          %{"name" => "B", "config" => "{\"show-modal\":true}"}
        ]
      }
    ] ++ (@get_context_response["experiments"])
  }

  defp audience_context_response do
    update_experiment(@get_context_response, "exp_test_ab", fn exp ->
      Map.put(exp, "audience", Jason.encode!(%{
        "filter" => [%{"gte" => [%{"var" => "age"}, %{"value" => 20}]}]
      }))
    end)
  end

  defp audience_strict_context_response do
    response = audience_context_response()
    update_experiment(response, "exp_test_ab", fn exp ->
      exp
      |> Map.put("audienceStrict", true)
      |> Map.update!("variants", fn variants ->
        Enum.map(variants, fn v ->
          if v["name"] == "A" do
            %{v | "config" => "{\"banner.size\":\"tiny\"}"}
          else
            v
          end
        end)
      end)
    end)
  end

  defp disjointed_context_response do
    response = @get_context_response
    response = update_experiment(response, "exp_test_ab", fn exp ->
      exp
      |> Map.put("audienceStrict", true)
      |> Map.put("audience", Jason.encode!(%{
        "filter" => [%{"gte" => [%{"var" => "age"}, %{"value" => 20}]}]
      }))
      |> Map.update!("variants", fn variants ->
        Enum.with_index(variants)
        |> Enum.map(fn {v, i} ->
          if i == @expected_variants["exp_test_ab"] do
            %{v | "config" => Jason.encode!(%{"icon" => "arrow"})}
          else
            v
          end
        end)
      end)
    end)
    update_experiment(response, "exp_test_abc", fn exp ->
      exp
      |> Map.put("audienceStrict", true)
      |> Map.put("audience", Jason.encode!(%{
        "filter" => [%{"lt" => [%{"var" => "age"}, %{"value" => 20}]}]
      }))
      |> Map.update!("variants", fn variants ->
        Enum.with_index(variants)
        |> Enum.map(fn {v, i} ->
          if i == @expected_variants["exp_test_abc"] do
            %{v | "config" => Jason.encode!(%{"icon" => "circle"})}
          else
            v
          end
        end)
      end)
    end)
  end

  defp update_experiment(response, name, fun) do
    experiments = Enum.map(response["experiments"], fn exp ->
      if exp["name"] == name, do: fun.(exp), else: exp
    end)
    %{response | "experiments" => experiments}
  end

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

  describe "constructor and initialization" do
    test "should be ready with data" do
      ctx = start_context(@get_context_response)
      assert Context.is_ready?(ctx) == true
      assert Context.is_failed?(ctx) == false
    end

    test "should not be finalized initially" do
      ctx = start_context(@get_context_response)
      assert Context.is_finalized?(ctx) == false
      assert Context.is_finalizing?(ctx) == false
    end

    test "should load experiment data" do
      ctx = start_context(@get_context_response)
      experiment_names = Context.experiments(ctx)
      expected_names = Enum.map(@get_context_response["experiments"], & &1["name"])
      assert experiment_names == expected_names
    end

    test "should return correct treatment for each experiment" do
      ctx = start_context(@get_context_response)
      for exp <- @get_context_response["experiments"] do
        expected = Map.get(@expected_variants, exp["name"])
        assert Context.treatment(ctx, exp["name"]) == expected,
          "Expected treatment #{expected} for #{exp["name"]}"
      end
    end

    test "should return correct peek for each experiment" do
      ctx = start_context(@get_context_response)
      for exp <- @get_context_response["experiments"] do
        expected = Map.get(@expected_variants, exp["name"])
        assert Context.peek(ctx, exp["name"]) == expected,
          "Expected peek #{expected} for #{exp["name"]}"
      end
    end
  end

  describe "unit management" do
    test "should set a unit" do
      ctx = start_context(@get_context_response, %{})
      Context.set_unit(ctx, "session_id", "e791e240fcd3df7d238cfc285f475e8152fcc0ec")
      Context.set_unit(ctx, "user_id", "123456789")
      Context.set_unit(ctx, "email", "bleh@absmartly.com")

      assert Context.get_unit(ctx, "session_id") == "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
      assert Context.get_unit(ctx, "user_id") == "123456789"
      assert Context.get_unit(ctx, "email") == "bleh@absmartly.com"

      units = Context.get_units(ctx)
      assert units == %{
        "session_id" => "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
        "user_id" => "123456789",
        "email" => "bleh@absmartly.com"
      }
    end

    test "should error on duplicate unit type set with different value" do
      ctx = start_context(@get_context_response)
      assert {:error, :duplicate_unit} = Context.set_unit(ctx, "session_id", "new_id")
    end

    test "should not error if set to same value" do
      ctx = start_context(@get_context_response)
      assert :ok = Context.set_unit(ctx, "session_id", "e791e240fcd3df7d238cfc285f475e8152fcc0ec")
    end

    test "should error after finalized call" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert {:error, :finalized} = Context.set_unit(ctx, "test", "test")
    end

    test "should set multiple units" do
      ctx = start_context(@get_context_response, %{})
      Context.set_units(ctx, %{
        "session_id" => "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
        "user_id" => "123456789"
      })
      assert Context.get_unit(ctx, "session_id") == "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
      assert Context.get_unit(ctx, "user_id") == "123456789"
    end
  end

  describe "attribute management" do
    test "should get the last set attribute" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "attr1", "value1")
      Context.set_attribute(ctx, "attr1", "value2")
      assert Context.get_attribute(ctx, "attr1") == "value2"
    end

    test "should set an attribute" do
      ctx = start_context(@get_context_response)
      Context.set_attribute(ctx, "attr1", "value1")
      Context.set_attribute(ctx, "attr2", "value2")
      Context.set_attribute(ctx, "attr3", 15)
      assert Context.get_attribute(ctx, "attr1") == "value1"
      assert Context.get_attribute(ctx, "attr2") == "value2"
      assert Context.get_attribute(ctx, "attr3") == 15
    end

    test "should return nil for unset attribute" do
      ctx = start_context(@get_context_response)
      assert Context.get_attribute(ctx, "not_set") == nil
    end
  end

  describe "peek" do
    test "should not queue exposures" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      for exp <- @get_context_response["experiments"] do
        expected = Map.get(@expected_variants, exp["name"])
        assert Context.peek(ctx, exp["name"]) == expected
      end

      assert Context.pending(ctx) == 0
    end

    test "should return override variant" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      for exp <- @get_context_response["experiments"] do
        expected = Map.get(@expected_variants, exp["name"])
        Context.set_override(ctx, exp["name"], expected + 11)
      end
      Context.set_override(ctx, "not_found", 3)

      for exp <- @get_context_response["experiments"] do
        expected = Map.get(@expected_variants, exp["name"])
        assert Context.peek(ctx, exp["name"]) == expected + 11
      end
      assert Context.peek(ctx, "not_found") == 3

      assert Context.pending(ctx) == 0
    end

    test "should return assigned variant on audience mismatch in non-strict mode" do
      ctx = start_context(audience_context_response())
      assert Context.peek(ctx, "exp_test_ab") == 1
    end

    test "should return control variant on audience mismatch in strict mode" do
      ctx = start_context(audience_strict_context_response())
      assert Context.peek(ctx, "exp_test_ab") == 0
    end
  end

  describe "treatment" do
    test "should queue exposures" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      for exp <- @get_context_response["experiments"] do
        Context.treatment(ctx, exp["name"])
      end

      assert Context.pending(ctx) == length(@get_context_response["experiments"])
    end

    test "should queue exposures after peek" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      for exp <- @get_context_response["experiments"] do
        Context.peek(ctx, exp["name"])
      end

      assert Context.pending(ctx) == 0

      for exp <- @get_context_response["experiments"] do
        Context.treatment(ctx, exp["name"])
      end

      assert Context.pending(ctx) == length(@get_context_response["experiments"])
    end

    test "should queue exposures only once" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      for exp <- @get_context_response["experiments"] do
        Context.treatment(ctx, exp["name"])
      end

      assert Context.pending(ctx) == length(@get_context_response["experiments"])

      for exp <- @get_context_response["experiments"] do
        Context.treatment(ctx, exp["name"])
      end

      assert Context.pending(ctx) == length(@get_context_response["experiments"])
    end

    test "should return 0 for unknown/stopped experiment" do
      ctx = start_context(@get_context_response)
      assert Context.treatment(ctx, "not_found") == 0
      assert Context.pending(ctx) == 1
    end

    test "should not re-queue exposure on unknown experiment" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      assert Context.treatment(ctx, "not_found") == 0
      assert Context.pending(ctx) == 1

      assert Context.treatment(ctx, "not_found") == 0
      assert Context.pending(ctx) == 1
    end

    test "should queue exposure with audienceMismatch true on audience mismatch in non-strict mode" do
      ctx = start_context(audience_context_response())
      assert Context.treatment(ctx, "exp_test_ab") == 1
      assert Context.pending(ctx) == 1
    end

    test "should return control variant on audience mismatch in strict mode" do
      ctx = start_context(audience_strict_context_response())
      assert Context.treatment(ctx, "exp_test_ab") == 0
      assert Context.pending(ctx) == 1
    end

    test "should queue exposure with override variant" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      Context.set_override(ctx, "exp_test_ab", 5)
      Context.set_override(ctx, "not_found", 3)

      assert Context.treatment(ctx, "exp_test_ab") == 5
      assert Context.treatment(ctx, "not_found") == 3

      assert Context.pending(ctx) == 2
    end

    test "should error after finalized call" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1

      Context.finalize(ctx)
      assert {:error, :finalized} = Context.treatment(ctx, "exp_test_ab")
    end

    test "should return full-on variant when full_on_variant is set" do
      ctx = start_context(@get_context_response)
      assert Context.treatment(ctx, "exp_test_fullon") == 2
    end

    test "should return correct variant for each experiment" do
      ctx = start_context(@get_context_response)
      for {name, expected} <- @expected_variants do
        assert Context.treatment(ctx, name) == expected
      end
    end
  end

  describe "variable_value" do
    test "should return default when unassigned in strict mode" do
      ctx = start_context(audience_strict_context_response())
      assert Context.variable_value(ctx, "banner.size", 17) == 17
    end

    test "should return variable value when overridden" do
      ctx = start_context(audience_strict_context_response())
      Context.set_override(ctx, "exp_test_ab", 0)
      assert Context.variable_value(ctx, "banner.size", 17) == "tiny"
    end

    test "should return correct variable values" do
      ctx = start_context(@get_context_response)
      for {key, expected} <- @expected_variables do
        assert Context.variable_value(ctx, key, 17) == expected,
          "Expected #{inspect(expected)} for variable #{key}"
      end
    end

    test "should return default for ineligible experiment" do
      ctx = start_context(@get_context_response)
      assert Context.variable_value(ctx, "card.width", "default") == "default"
    end

    test "should queue exposures" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      all_variable_keys = Map.merge(@expected_variables, %{"card.width" => "default"})
      for {key, _expected} <- all_variable_keys do
        Context.variable_value(ctx, key, 17)
      end

      assert Context.pending(ctx) == length(@get_context_response["experiments"])
    end

    test "should queue exposures only once" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      all_variable_keys = Map.merge(@expected_variables, %{"card.width" => "default"})
      for {key, _expected} <- all_variable_keys do
        Context.variable_value(ctx, key, 17)
      end

      count = Context.pending(ctx)

      for {key, _expected} <- all_variable_keys do
        Context.variable_value(ctx, key, 17)
      end

      assert Context.pending(ctx) == count
    end

    test "should return default for unknown variable" do
      ctx = start_context(@get_context_response)
      assert Context.variable_value(ctx, "not.found", 17) == 17
    end

    test "should error after finalized call" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert {:error, :finalized} = Context.variable_value(ctx, "banner.size", 17)
    end

    test "conflicting key disjoint audiences" do
      ctx1 = start_context(disjointed_context_response())
      ctx2 = start_context(disjointed_context_response())

      Context.set_attribute(ctx1, "age", 20)
      assert Context.variable_value(ctx1, "icon", "square") == "arrow"

      Context.set_attribute(ctx2, "age", 19)
      assert Context.variable_value(ctx2, "icon", "square") == "circle"
    end
  end

  describe "peek_variable_value" do
    test "should return default when unassigned in strict mode" do
      ctx = start_context(audience_strict_context_response())
      assert Context.peek_variable_value(ctx, "banner.size", 17) == 17
    end

    test "should return variable value when overridden" do
      ctx = start_context(audience_strict_context_response())
      Context.set_override(ctx, "exp_test_ab", 0)
      assert Context.peek_variable_value(ctx, "banner.size", 17) == "tiny"
    end

    test "should return correct variable values" do
      ctx = start_context(@get_context_response)
      for {key, expected} <- @expected_variables do
        assert Context.peek_variable_value(ctx, key, 17) == expected,
          "Expected #{inspect(expected)} for variable #{key}"
      end
    end

    test "should not queue exposures" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      for {key, _expected} <- @expected_variables do
        Context.peek_variable_value(ctx, key, 17)
      end

      assert Context.pending(ctx) == 0
    end

    test "should queue exposures after peek via variable_value" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0

      all_variable_keys = Map.merge(@expected_variables, %{"card.width" => "default"})
      for {key, _expected} <- all_variable_keys do
        Context.peek_variable_value(ctx, key, 17)
      end

      assert Context.pending(ctx) == 0

      for {key, _expected} <- all_variable_keys do
        Context.variable_value(ctx, key, 17)
      end

      assert Context.pending(ctx) == length(@get_context_response["experiments"])
    end

    test "conflicting key disjoint audiences" do
      ctx1 = start_context(disjointed_context_response())
      ctx2 = start_context(disjointed_context_response())

      Context.set_attribute(ctx1, "age", 20)
      assert Context.peek_variable_value(ctx1, "icon", "square") == "arrow"

      Context.set_attribute(ctx2, "age", 19)
      assert Context.peek_variable_value(ctx2, "icon", "square") == "circle"
    end
  end

  describe "variable_keys" do
    test "should return all active variable keys" do
      ctx = start_context(@get_context_response)
      keys = Context.variable_keys(ctx)
      assert "banner.border" in keys
      assert "banner.size" in keys
      assert "button.color" in keys
      assert "card.width" in keys
      assert "submit.color" in keys
      assert "submit.shape" in keys
      assert "submit.size" in keys
    end
  end

  describe "track" do
    test "should queue goals" do
      ctx = start_context(@get_context_response)
      Context.track(ctx, "goal1", %{"amount" => 125, "hours" => 245})
      Context.track(ctx, "goal2", %{"tries" => 7})

      assert Context.pending(ctx) == 2
    end

    test "should accept nil properties" do
      ctx = start_context(@get_context_response)
      Context.track(ctx, "goal1")
      assert Context.pending(ctx) == 1
    end

    test "should error after finalized call" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert {:error, :finalized} = Context.track(ctx, "goal1")
    end

    test "should include goals with exposures in pending count" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      Context.track(ctx, "goal1")
      assert Context.pending(ctx) == 2
    end
  end

  describe "publish" do
    test "should not publish when queue is empty" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0
      assert :ok = Context.publish(ctx)
    end

    test "should clear queue on success" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1
      Context.publish(ctx)
      assert Context.pending(ctx) == 0
    end

    test "should error after finalized call" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert {:error, :finalized} = Context.publish(ctx)
    end

    test "should include exposures and goals" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      Context.track(ctx, "goal1", %{"amount" => 125})
      assert Context.pending(ctx) == 2
      Context.publish(ctx)
      assert Context.pending(ctx) == 0
    end
  end

  describe "finalize" do
    test "should publish pending data" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      assert Context.pending(ctx) == 1
      Context.finalize(ctx)
      assert Context.is_finalized?(ctx) == true
      assert Context.pending(ctx) == 0
    end

    test "should be idempotent" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert Context.is_finalized?(ctx) == true
      Context.finalize(ctx)
      assert Context.is_finalized?(ctx) == true
    end

    test "should not publish when queue is empty" do
      ctx = start_context(@get_context_response)
      assert Context.pending(ctx) == 0
      Context.finalize(ctx)
      assert Context.is_finalized?(ctx) == true
    end

    test "should clear queue on success" do
      ctx = start_context(@get_context_response)
      Context.treatment(ctx, "exp_test_ab")
      Context.track(ctx, "goal1")
      assert Context.pending(ctx) == 2
      Context.finalize(ctx)
      assert Context.pending(ctx) == 0
    end
  end

  describe "override" do
    test "should override treatment" do
      ctx = start_context(@get_context_response)
      Context.set_override(ctx, "exp_test_ab", 5)
      assert Context.treatment(ctx, "exp_test_ab") == 5
    end

    test "should override for unknown experiment" do
      ctx = start_context(@get_context_response)
      Context.set_override(ctx, "not_found", 3)
      assert Context.treatment(ctx, "not_found") == 3
    end

    test "should error after finalized call" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert {:error, :finalized} = Context.set_override(ctx, "exp_test_ab", 5)
    end

    test "should override multiple experiments" do
      ctx = start_context(@get_context_response)
      Context.set_overrides(ctx, %{
        "exp_test_ab" => 5,
        "exp_test_abc" => 3
      })
      assert Context.treatment(ctx, "exp_test_ab") == 5
      assert Context.treatment(ctx, "exp_test_abc") == 3
    end
  end

  describe "custom_assignment" do
    test "should override natural assignment and set custom flag" do
      ctx = start_context(@get_context_response)
      Context.set_custom_assignment(ctx, "exp_test_ab", 3)
      assert Context.treatment(ctx, "exp_test_ab") == 3
    end

    test "should not override full-on assignment" do
      ctx = start_context(@get_context_response)
      Context.set_custom_assignment(ctx, "exp_test_fullon", 3)
      assert Context.treatment(ctx, "exp_test_fullon") == 2
    end

    test "should not override non-eligible assignment" do
      ctx = start_context(@get_context_response)
      Context.set_custom_assignment(ctx, "exp_test_not_eligible", 3)
      assert Context.treatment(ctx, "exp_test_not_eligible") == 0
    end

    test "should error after finalized call" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert {:error, :finalized} = Context.set_custom_assignment(ctx, "exp_test_ab", 3)
    end

    test "should set multiple custom assignments" do
      ctx = start_context(@get_context_response)
      Context.set_custom_assignments(ctx, %{
        "exp_test_ab" => 3,
        "exp_test_abc" => 1
      })
      assert Context.treatment(ctx, "exp_test_ab") == 3
      assert Context.treatment(ctx, "exp_test_abc") == 1
    end
  end

  describe "refresh" do
    test "should load new data" do
      ctx = start_context(@get_context_response)
      Context.refresh(ctx, @refresh_context_response)

      experiment_names = Context.experiments(ctx)
      expected_names = Enum.map(@refresh_context_response["experiments"], & &1["name"])
      assert experiment_names == expected_names
    end

    test "should not re-queue exposures after refresh when not changed" do
      ctx = start_context(@get_context_response)

      for exp <- @get_context_response["experiments"] do
        Context.treatment(ctx, exp["name"])
      end

      assert Context.pending(ctx) == length(@get_context_response["experiments"])

      Context.refresh(ctx, @refresh_context_response)

      for exp <- @get_context_response["experiments"] do
        Context.treatment(ctx, exp["name"])
      end

      assert Context.pending(ctx) == length(@get_context_response["experiments"])

      for exp <- @refresh_context_response["experiments"] do
        Context.treatment(ctx, exp["name"])
      end

      assert Context.pending(ctx) == length(@refresh_context_response["experiments"])
    end

    test "should not re-queue when not changed on audience mismatch" do
      ctx = start_context(audience_strict_context_response())

      assert Context.treatment(ctx, "exp_test_ab") == 0
      assert Context.pending(ctx) == 1

      Context.refresh(ctx, audience_strict_context_response())

      assert Context.treatment(ctx, "exp_test_ab") == 0
      assert Context.pending(ctx) == 1
    end

    test "should not re-queue when not changed with override" do
      ctx = start_context(audience_strict_context_response())

      Context.set_override(ctx, "exp_test_ab", 3)
      assert Context.treatment(ctx, "exp_test_ab") == 3
      assert Context.pending(ctx) == 1

      Context.refresh(ctx, audience_strict_context_response())

      assert Context.treatment(ctx, "exp_test_ab") == 3
      assert Context.pending(ctx) == 1
    end

    test "should error after finalized call" do
      ctx = start_context(@get_context_response)
      Context.finalize(ctx)
      assert {:error, :finalized} = Context.refresh(ctx, @refresh_context_response)
    end

    test "should keep overrides" do
      ctx = start_context(@get_context_response)
      Context.set_override(ctx, "not_found", 3)
      assert Context.peek(ctx, "not_found") == 3

      Context.refresh(ctx, @refresh_context_response)
      assert Context.peek(ctx, "not_found") == 3
    end

    test "should keep custom assignments" do
      ctx = start_context(@get_context_response)
      Context.set_custom_assignment(ctx, "exp_test_ab", 3)
      assert Context.peek(ctx, "exp_test_ab") == 3

      Context.refresh(ctx, @refresh_context_response)
      assert Context.peek(ctx, "exp_test_ab") == 3
    end

    test "should pick up changes in experiment stopped" do
      ctx = start_context(@get_context_response)

      assert Context.treatment(ctx, "exp_test_abc") == @expected_variants["exp_test_abc"]
      assert Context.pending(ctx) == 1

      stopped_response = %{
        @get_context_response |
        "experiments" => Enum.filter(@get_context_response["experiments"], fn e ->
          e["name"] != "exp_test_abc"
        end)
      }

      Context.refresh(ctx, stopped_response)

      assert Context.treatment(ctx, "exp_test_abc") == 0
      assert Context.pending(ctx) == 2
    end

    test "should pick up changes in experiment started" do
      ctx = start_context(@get_context_response)

      assert Context.treatment(ctx, "exp_test_new") == 0
      assert Context.pending(ctx) == 1

      Context.refresh(ctx, @refresh_context_response)

      assert Context.treatment(ctx, "exp_test_new") == 1
      assert Context.pending(ctx) == 2
    end

    test "should pick up changes in experiment fullon" do
      ctx = start_context(@get_context_response)

      assert Context.treatment(ctx, "exp_test_abc") == @expected_variants["exp_test_abc"]
      assert Context.pending(ctx) == 1

      full_on_response = update_experiment(@get_context_response, "exp_test_abc", fn exp ->
        Map.put(exp, "fullOnVariant", 1)
      end)

      Context.refresh(ctx, full_on_response)

      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.pending(ctx) == 2
    end

    test "should pick up changes in experiment traffic split" do
      ctx = start_context(@get_context_response)

      assert Context.treatment(ctx, "exp_test_not_eligible") == @expected_variants["exp_test_not_eligible"]
      assert Context.pending(ctx) == 1

      scaled_up_response = update_experiment(@get_context_response, "exp_test_not_eligible", fn exp ->
        Map.put(exp, "trafficSplit", [0.0, 1.0])
      end)

      Context.refresh(ctx, scaled_up_response)

      assert Context.treatment(ctx, "exp_test_not_eligible") == 2
      assert Context.pending(ctx) == 2
    end

    test "should pick up changes in experiment iteration" do
      ctx = start_context(@get_context_response)

      assert Context.treatment(ctx, "exp_test_abc") == @expected_variants["exp_test_abc"]
      assert Context.pending(ctx) == 1

      iterated_response = update_experiment(@get_context_response, "exp_test_abc", fn exp ->
        exp
        |> Map.put("iteration", 2)
        |> Map.put("trafficSeedHi", 398724581)
        |> Map.put("seedHi", 34737352)
      end)

      Context.refresh(ctx, iterated_response)

      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.pending(ctx) == 2
    end

    test "should pick up changes in experiment id" do
      ctx = start_context(@get_context_response)

      assert Context.treatment(ctx, "exp_test_abc") == @expected_variants["exp_test_abc"]
      assert Context.pending(ctx) == 1

      id_changed_response = update_experiment(@get_context_response, "exp_test_abc", fn exp ->
        exp
        |> Map.put("id", 11)
        |> Map.put("trafficSeedHi", 398724581)
        |> Map.put("seedHi", 34737352)
      end)

      Context.refresh(ctx, id_changed_response)

      assert Context.treatment(ctx, "exp_test_abc") == 1
      assert Context.pending(ctx) == 2
    end
  end

  describe "custom_field_keys" do
    test "should return custom field keys" do
      ctx = start_context(@get_context_response)
      keys = Context.custom_field_keys(ctx, "exp_test_abc")
      assert "country" in keys
      assert "json_object" in keys
      assert "json_array" in keys
      assert "json_number" in keys
      assert "json_string" in keys
      assert "json_boolean" in keys
      assert "json_null" in keys
      assert "json_invalid" in keys
    end

    test "should return empty list for experiment without custom fields" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_keys(ctx, "exp_test_ab") == []
    end

    test "should return empty list for unknown experiment" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_keys(ctx, "not_found") == []
    end
  end

  describe "custom_field_value" do
    test "should return string custom field value" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "country") == "US,PT,ES,DE,FR"
    end

    test "should return parsed json object field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "json_object") == %{"123" => 1, "456" => 0}
    end

    test "should return parsed json array field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "json_array") == ["hello", "world"]
    end

    test "should return parsed json number field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "json_number") == 123
    end

    test "should return parsed json string field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "json_string") == "hello"
    end

    test "should return parsed json boolean field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "json_boolean") == true
    end

    test "should return parsed json null field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "json_null") == nil
    end

    test "should return nil for invalid json field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "json_invalid") == nil
    end

    test "should return string field from custom fields experiment" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_custom_fields", "country") == "US,PT,ES"
      assert Context.custom_field_value(ctx, "exp_test_custom_fields", "languages") == "en-US,en-GB,pt-PT,pt-BR,es-ES,es-MX"
    end

    test "should return text field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_custom_fields", "text_field") == "hello text"
    end

    test "should return string_field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_custom_fields", "string_field") == "hello string"
    end

    test "should return number field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_custom_fields", "number_field") == 123.0
    end

    test "should return boolean true field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_custom_fields", "boolean_field") == true
    end

    test "should return boolean false field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_custom_fields", "false_boolean_field") == false
    end

    test "should return value as-is for invalid type" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_custom_fields", "invalid_type_field") == "invalid"
    end

    test "should return nil for non-existent field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_abc", "not_found") == nil
    end

    test "should return nil for experiment without custom fields" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "exp_test_ab", "country") == nil
    end

    test "should return nil for unknown experiment" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value(ctx, "not_found", "country") == nil
    end
  end

  describe "custom_field_value_type" do
    test "should return custom field value type" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value_type(ctx, "exp_test_abc", "country") == "string"
      assert Context.custom_field_value_type(ctx, "exp_test_abc", "json_object") == "json"
    end

    test "should return nil for non-existent field" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value_type(ctx, "exp_test_abc", "not_found") == nil
    end

    test "should return nil for unknown experiment" do
      ctx = start_context(@get_context_response)
      assert Context.custom_field_value_type(ctx, "not_found", "country") == nil
    end
  end
end
