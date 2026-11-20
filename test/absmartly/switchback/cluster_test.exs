defmodule ABSmartly.Switchback.ClusterTest do
  @moduledoc """
  Cluster serving through the public `ABSmartly.Context` API: ports of the
  Java SDK's `ContextSwitchbackClusterTest`, `ContextSwitchbackClusterRuleTest`
  and `SwitchbackServerParityTest` (java-sdk#15). Each test names the Java
  test it ports. Expected variants come from the assigner over the raw
  cluster key, which the golden vectors pin, and from a few independent
  murmur3 schedules.
  """

  use ExUnit.Case, async: true

  import ABSmartly.SwitchbackTestSupport

  alias ABSmartly.Context
  alias ABSmartly.Switchback.Assigner

  @hour 3_600_000
  @anchor 1_767_225_600_000
  @arms 3
  @store "store_id"
  @device "device_id"
  @user "user_id"
  @session "session_id"
  @uid "e791e240fcd3df7d238cfc285f475e8152fcc0ec"

  # ContextSwitchbackTest's seed (-5, -7).
  @seed_hi -5
  @seed_lo -7
  @seed Bitwise.bor(Bitwise.bsl(@seed_hi, 32), Bitwise.band(@seed_lo, 0xFFFFFFFF))

  defp experiment(clusters, overrides \\ %{}) do
    %{
      "id" => 1,
      "name" => "exp_sb",
      "unitType" => @store,
      "iteration" => 1,
      "seedHi" => @seed_hi,
      "seedLo" => @seed_lo,
      "split" => List.duplicate(1.0 / @arms, @arms),
      "variants" =>
        for(i <- 0..(@arms - 1), do: %{"name" => "#{i}", "config" => ~s({"sb.arm":#{i}})}),
      "trafficSeedHi" => 1,
      "trafficSeedLo" => 2,
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => 0,
      "applications" => [%{"name" => "website"}],
      "randomizationType" => "switchback",
      "switchbackClusters" => clusters,
      "switchbackStartAt" => @anchor,
      "switchbackPeriodMs" => @hour,
      "switchbackDesignType" => "balanced_block"
    }
    |> Map.merge(overrides)
  end

  defp attribute_switchback(path, overrides \\ %{}),
    do: experiment(clusters([{@store, path}]), overrides)

  defp expected(key, period), do: Assigner.assign(key, period, @seed, @arms)
  defp expected_schedule(key), do: for(i <- 0..11, do: expected(key, i))

  defp ctx(clock, experiments, units \\ %{@store => @uid}, attributes \\ []) do
    start(clock, units, %{"experiments" => List.wrap(experiments)}, attributes: attributes)
  end

  defp peek_schedule(ctx, clock) do
    for i <- 0..11 do
      set(clock, @anchor + i * @hour)
      Context.peek(ctx, "exp_sb")
    end
  end

  defp refresh(ctx, experiments),
    do: :ok = Context.refresh(ctx, context_data(%{"experiments" => List.wrap(experiments)}))

  defp exposure(variant, exposed_at, eligible, audience_mismatch) do
    %{
      "id" => 1,
      "name" => "exp_sb",
      "unit" => @store,
      "variant" => variant,
      "exposedAt" => exposed_at,
      "assigned" => true,
      "eligible" => eligible,
      "overridden" => false,
      "fullOn" => false,
      "custom" => false,
      "audienceMismatch" => audience_mismatch,
      "ruleOverride" => false
    }
  end

  setup do
    {:ok, clock: clock(@anchor)}
  end

  describe "ContextSwitchbackClusterTest" do
    # unitUidIsNeverTheClusterKey
    test "the unit uid is never the cluster key", %{clock: clock} do
      {ctx, _} = ctx(clock, attribute_switchback("city"))

      for i <- 0..2 do
        set(clock, @anchor + i * @hour)
        assert Context.treatment(ctx, "exp_sb") == 0
      end

      assert Context.pending(ctx) == 0
    end

    # numericUnitUidClustersLikeItsCanonicalString
    test "a numeric uid clusters like its canonical string", %{clock: clock} do
      for {numeric, text} <- [
            {123_456_789, "123456789"},
            {123_456_789.0, "123456789"},
            {9_007_199_254_740_993, "9007199254740992"},
            {125.75, "126"}
          ] do
        results =
          for uid <- [numeric, text] do
            set(clock, @anchor)
            {ctx, events} = ctx(clock, attribute_switchback("city"), %{@store => uid})
            :ok = Context.set_attribute(ctx, "city", "Lisboa")
            Context.treatment(ctx, "exp_sb")
            [event] = publish_events(ctx, events)
            {Map.take(event, ["units", "exposures"]), peek_schedule(ctx, clock)}
          end

        [{numeric_event, numeric_schedule}, {text_event, text_schedule}] = results
        assert numeric_schedule == expected_schedule("Lisboa")
        assert numeric_schedule == text_schedule
        assert numeric_event == text_event

        assert numeric_event["units"] == [
                 %{"type" => @store, "uid" => ABSmartly.Utils.hash_unit(text)}
               ]
      end
    end

    # numericUnitUidMatchesTheIndependentReference
    test "a numeric uid matches the independent reference", %{clock: clock} do
      schedule = [0, 2, 1, 0, 1, 2, 0, 1, 2, 2, 1, 0]

      for {uid, hash} <- [
            {123_456_789, "JfnnlDI7RTiF9RgfG2JNCw"},
            {9_007_199_254_740_993, "OngwCmjeKhIQyeNybDy4eg"}
          ] do
        set(clock, @anchor)
        {ctx, events} = ctx(clock, attribute_switchback("region"), %{@store => uid})
        :ok = Context.set_attribute(ctx, "region", 123_456_789)
        Context.treatment(ctx, "exp_sb")
        [event] = publish_events(ctx, events)
        assert event["units"] == [%{"type" => @store, "uid" => hash}]
        assert event["exposures"] == [exposure(hd(schedule), @anchor, true, false)]
        assert peek_schedule(ctx, clock) == schedule
      end
    end

    # attributeSourceServesTheRawAttributeValue
    test "an attribute source serves the raw attribute value", %{clock: clock} do
      {ctx, _} = ctx(clock, attribute_switchback("city"))
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      assert peek_schedule(ctx, clock) == [0, 2, 1, 2, 1, 0, 1, 0, 2, 0, 1, 2]
      assert peek_schedule(ctx, clock) == expected_schedule("Lisboa")
    end

    # unitsSharingAnAttributeValueShareTheSchedule
    test "units sharing an attribute value share the schedule", %{clock: clock} do
      schedules =
        for {uid, city} <- [{@uid, "Lisboa"}, {"another-store", "Lisboa"}, {@uid, "Porto"}] do
          set(clock, @anchor)
          {ctx, _} = ctx(clock, attribute_switchback("city"), %{@store => uid})
          :ok = Context.set_attribute(ctx, "city", city)
          peek_schedule(ctx, clock)
        end

      assert schedules == [
               expected_schedule("Lisboa"),
               expected_schedule("Lisboa"),
               expected_schedule("Porto")
             ]

      refute expected_schedule("Lisboa") == expected_schedule("Porto")
    end

    # nestedAndArrayPathsAndIntegerValuesResolve
    test "nested and array paths and integer values resolve", %{clock: clock} do
      for {path, name, value, key} <- [
            {"geo/city", "geo", %{"city" => "Porto"}, "Porto"},
            {"items/1/city", "items", [%{"city" => "Lisbon"}, %{"city" => "Faro"}], "Faro"},
            {"region", "region", 42, "42"},
            # Read through the JSON encoding, as the Collector decodes it.
            {"geo/city", "geo", %{city: :c}, "c"},
            {"city", "city", :c, "c"}
          ] do
        set(clock, @anchor)
        {ctx, _} = ctx(clock, attribute_switchback(path))
        :ok = Context.set_attribute(ctx, name, value)
        assert peek_schedule(ctx, clock) == expected_schedule(key), path
      end

      set(clock, @anchor + 10)
      {floating, _} = ctx(clock, attribute_switchback("city"))
      :ok = Context.set_attribute(floating, "city", 2.0)
      assert Context.treatment(floating, "exp_sb") == 0
      assert Context.pending(floating) == 0
    end

    # valuesWithoutAClusterKeyAreIneligible
    test "values without a cluster key are ineligible", %{clock: clock} do
      for value <- [nil, "", true, false, 1.5, 2.0, 3.0, -0.0, %{"a" => "b"}, ["x"], []] do
        set(clock, @anchor)
        {ctx, _} = ctx(clock, attribute_switchback("city"))
        :ok = Context.set_attribute(ctx, "city", value)
        set(clock, @anchor + 10)
        assert Context.treatment(ctx, "exp_sb") == 0, inspect(value)
        # Variant 0's own config, like any ineligible assignment.
        assert Context.variable_value(ctx, "sb.arm", -1) == 0, inspect(value)
        assert Context.pending(ctx) == 0, inspect(value)
      end

      set(clock, @anchor)
      {missing, _} = ctx(clock, attribute_switchback("geo/city"))
      :ok = Context.set_attribute(missing, "geo", %{"country" => "PT"})
      set(clock, @anchor + 10)
      assert Context.treatment(missing, "exp_sb") == 0
      assert Context.pending(missing) == 0
    end

    # unencodableAttributeValuesAreIneligible
    test "unencodable attribute values are ineligible", %{clock: clock} do
      for value <- [{1, 2}, %{"city" => self()}, %{"city" => <<255>>}, make_ref()] do
        {ctx, _} = ctx(clock, attribute_switchback("geo/city"))
        :ok = Context.set_attribute(ctx, "geo", value)
        assert Context.treatment(ctx, "exp_sb") == 0
        assert Context.pending(ctx) == 0
      end
    end

    # unservableConfigurationsAreIneligible
    test "unservable configurations are ineligible", %{clock: clock} do
      experiments =
        Enum.map(
          ["items/0", "items/-1/city", "", "geo.city", "'city", ~s("city)],
          &attribute_switchback/1
        ) ++
          [
            attribute_switchback("city", %{"switchbackPeriodMs" => nil}),
            attribute_switchback("city", %{"switchbackPeriodMs" => 0}),
            attribute_switchback("city", %{"switchbackPeriodMs" => -@hour}),
            attribute_switchback("city", %{"split" => [1.0]}),
            experiment(clusters([{@store, nil}]))
          ]

      for experiment <- experiments do
        set(clock, @anchor)
        {ctx, _} = ctx(clock, experiment)
        :ok = Context.set_attribute(ctx, "city", "Lisboa")
        :ok = Context.set_attribute(ctx, "items", [%{"city" => "Lisbon"}])

        for i <- 0..2 do
          set(clock, @anchor + i * @hour)
          assert Context.treatment(ctx, "exp_sb") == 0, inspect(experiment)
        end

        assert Context.pending(ctx) == 0, inspect(experiment)
      end
    end

    # missingOrEmptyClusterMapIsOnlyALegacyIneligibleControl
    test "a missing or empty cluster map is only a legacy ineligible control", %{clock: clock} do
      for clusters <- [nil, clusters([]), %{}] do
        experiment = attribute_switchback("city", %{"switchbackClusters" => clusters})
        {ctx, _} = ctx(clock, experiment)
        :ok = Context.set_attribute(ctx, "city", "Lisboa")
        assert Context.treatment(ctx, "exp_sb") == 0
        assert Context.variable_value(ctx, "sb.arm", -1) == 0
        assert Context.pending(ctx) == 0

        {other, _} = ctx(clock, experiment, %{@user => "u1"})
        :ok = Context.set_attribute(other, "city", "Lisboa")
        assert Context.treatment(other, "exp_sb") == 0
        assert Context.variable_value(other, "sb.arm", -1) == -1
        assert Context.pending(other) == 0
      end
    end

    # latestAttributeSetAtOrBeforeTheResolutionInstantIsUsed
    test "the latest attribute set at or before the resolution instant is used", %{clock: clock} do
      {ctx, _} = ctx(clock, attribute_switchback("city"))
      set(clock, @anchor + 2 * @hour)
      :ok = Context.set_attribute(ctx, "city", "Porto")
      set(clock, @anchor + 4 * @hour)
      :ok = Context.set_attribute(ctx, "city", "Lisboa")

      set(clock, @anchor + @hour)
      assert Context.peek(ctx, "exp_sb") == 0
      set(clock, @anchor + 3 * @hour)
      assert Context.peek(ctx, "exp_sb") == expected("Porto", 3)
      set(clock, @anchor + 4 * @hour)
      assert Context.peek(ctx, "exp_sb") == expected("Lisboa", 4)
    end

    # setAttributeMidPeriodDoesNotReassignWithinThePeriod
    test "setAttribute mid-period does not reassign within the period", %{clock: clock} do
      {ctx, _} = ctx(clock, attribute_switchback("city"))
      set(clock, @anchor + 10)
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)

      set(clock, @anchor + 20)
      :ok = Context.set_attribute(ctx, "city", "Porto")
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)
      assert Context.peek(ctx, "exp_sb") == expected("Lisboa", 0)
      assert Context.pending(ctx) == 1

      for i <- 1..11 do
        set(clock, @anchor + i * @hour)
        assert Context.treatment(ctx, "exp_sb") == expected("Porto", i)
      end

      assert Enum.any?(1..11, &(expected("Porto", &1) != expected("Lisboa", &1)))
      assert Context.pending(ctx) == 12
    end

    # Owner decision (php-sdk#13 Q2): changing a cluster attribute within a
    # period is not supported. The arm cached at the first read stays for the
    # period, before the exposure and after a publish, and the change applies
    # from the next period.
    test "the arm cached at the first read stays for the period, exposed or not", %{
      clock: clock
    } do
      {ctx, events} = ctx(clock, attribute_switchback("city"))
      assert expected("Lisboa", 0) != expected("Faro", 0)
      assert expected("Lisboa", 1) != expected("Faro", 1)

      set(clock, @anchor + 10)
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      assert Context.peek(ctx, "exp_sb") == expected("Lisboa", 0)

      set(clock, @anchor + 20)
      :ok = Context.set_attribute(ctx, "city", "Faro")
      assert Context.variable_value(ctx, "sb.arm", nil) == expected("Lisboa", 0)
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)

      assert publish_exposures(ctx, events) == [
               exposure(expected("Lisboa", 0), @anchor + 20, true, false)
             ]

      set(clock, @anchor + 30)
      :ok = Context.set_attribute(ctx, "city", "Faro")
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)
      assert Context.pending(ctx) == 0

      set(clock, @anchor + @hour)
      assert Context.treatment(ctx, "exp_sb") == expected("Faro", 1)

      assert publish_exposures(ctx, events) == [
               exposure(expected("Faro", 1), @anchor + @hour, true, false)
             ]
    end

    # attributeSetAfterAnIneligibleResolutionWaitsForTheNextPeriod
    test "an attribute set after an ineligible resolution waits for the next period", %{
      clock: clock
    } do
      {ctx, events} = ctx(clock, attribute_switchback("city"))
      set(clock, @anchor + 10)
      assert Context.treatment(ctx, "exp_sb") == 0
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      set(clock, @anchor + 20)
      assert Context.treatment(ctx, "exp_sb") == 0
      assert Context.pending(ctx) == 0

      set(clock, @anchor + @hour)
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 1)

      assert publish_exposures(ctx, events) == [
               exposure(expected("Lisboa", 1), @anchor + @hour, true, false)
             ]
    end

    # trafficChangesWithinThePeriodKeepThePeriodsBucket
    test "traffic changes within the period keep the period's key", %{clock: clock} do
      {ctx, _} = ctx(clock, attribute_switchback("city"))
      set(clock, @anchor + 10)
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)

      set(clock, @anchor + 20)
      :ok = Context.set_attribute(ctx, "city", "Porto")
      refresh(ctx, attribute_switchback("city", %{"trafficSplit" => [1.0, 0.0]}))
      assert Context.treatment(ctx, "exp_sb") == 0

      refresh(ctx, attribute_switchback("city"))
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)
      assert Context.pending(ctx) == 3

      set(clock, @anchor + @hour)
      assert Context.treatment(ctx, "exp_sb") == expected("Porto", 1)
    end

    # trafficRestoredWithinThePeriodKeepsTheKey
    test "traffic restored within the period keeps the key", %{clock: clock} do
      {ctx, events} = ctx(clock, attribute_switchback("city", %{"trafficSplit" => [1.0, 0.0]}))
      set(clock, @anchor + 10)
      :ok = Context.set_attribute(ctx, "city", "Faro")
      assert Context.treatment(ctx, "exp_sb") == 0

      set(clock, @anchor + 20)
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      refresh(ctx, attribute_switchback("city"))
      assert expected("Faro", 0) == 1
      assert Context.treatment(ctx, "exp_sb") == expected("Faro", 0)

      assert publish_exposures(ctx, events) == [
               exposure(0, @anchor + 10, false, false),
               exposure(expected("Faro", 0), @anchor + 20, true, false)
             ]
    end

    @gold ~s({"filter":[{"eq":[{"var":"tier"},{"value":"gold"}]}]})

    # audienceRevalidationAfterSetAttributeKeepsThePeriodsBucket
    test "audience revalidation after setAttribute keeps the period's key", %{clock: clock} do
      {ctx, events} = ctx(clock, attribute_switchback("city", %{"audience" => @gold}))
      set(clock, @anchor + 10)
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      :ok = Context.set_attribute(ctx, "tier", "gold")
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)

      set(clock, @anchor + 20)
      :ok = Context.set_attribute(ctx, "city", "Porto")
      :ok = Context.set_attribute(ctx, "tier", "silver")
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)

      assert publish_exposures(ctx, events) == [
               exposure(expected("Lisboa", 0), @anchor + 10, true, false),
               exposure(expected("Lisboa", 0), @anchor + 20, true, true)
             ]
    end

    # audienceRevalidationAfterAnIneligibleResolutionKeepsTheMissingKey
    test "audience revalidation after an ineligible resolution keeps the missing key", %{
      clock: clock
    } do
      {ctx, _} = ctx(clock, attribute_switchback("city", %{"audience" => @gold}))
      set(clock, @anchor + 10)
      :ok = Context.set_attribute(ctx, "tier", "gold")
      assert Context.treatment(ctx, "exp_sb") == 0

      set(clock, @anchor + 20)
      :ok = Context.set_attribute(ctx, "city", "Faro")
      :ok = Context.set_attribute(ctx, "tier", "silver")
      assert expected("Faro", 0) == 1
      assert Context.treatment(ctx, "exp_sb") == 0
      assert Context.pending(ctx) == 0

      set(clock, @anchor + @hour)
      assert Context.peek(ctx, "exp_sb") == expected("Faro", 1)
      set(clock, @anchor + 2 * @hour)
      assert expected("Faro", 2) == 2
      assert Context.peek(ctx, "exp_sb") == expected("Faro", 2)
    end

    # clusterPathChangesInvalidateThePeriod
    test "cluster path changes invalidate the period", %{clock: clock} do
      {ctx, _} = ctx(clock, attribute_switchback("city"))
      set(clock, @anchor + 10)
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      :ok = Context.set_attribute(ctx, "geo", %{"city" => "Porto"})
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)
      assert Context.pending(ctx) == 1

      refresh(ctx, attribute_switchback("city"))
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)
      assert Context.pending(ctx) == 1

      refresh(ctx, attribute_switchback("geo/city"))
      assert Context.treatment(ctx, "exp_sb") == expected("Porto", 0)
      assert Context.pending(ctx) == 2

      refresh(
        ctx,
        attribute_switchback("geo/city", %{"switchbackClusterValues" => ["Porto", "Faro"]})
      )

      assert Context.treatment(ctx, "exp_sb") == expected("Porto", 0)
      assert Context.pending(ctx) == 3
    end

    # linkedUnitTypeChangeRekeysThePeriod
    test "a linked unit type change re-keys the period", %{clock: clock} do
      {ctx, events} =
        ctx(clock, attribute_switchback("city"), %{@store => @uid, @user => "user-0002"})

      set(clock, @anchor + 1)
      :ok = Context.set_attribute(ctx, "city", "Lisboa")
      :ok = Context.set_attribute(ctx, "ucity", "Faro")
      assert Context.treatment(ctx, "exp_sb") == expected("Lisboa", 0)

      refresh(ctx, experiment(clusters([{@user, "ucity"}])))
      assert Context.treatment(ctx, "exp_sb") == expected("Faro", 0)
      assert Enum.map(publish_exposures(ctx, events), & &1["unit"]) == [@store, @user]
    end

    # customAssignmentAppliesOnlyToUnitsWithAClusterKey
    test "a custom assignment applies only to units with a cluster key", %{clock: clock} do
      {keyed, _} = ctx(clock, attribute_switchback("city"))
      :ok = Context.set_attribute(keyed, "city", "Lisboa")
      :ok = Context.set_custom_assignment(keyed, "exp_sb", 2)
      assert Context.treatment(keyed, "exp_sb") == 2

      {unkeyed, _} = ctx(clock, attribute_switchback("city"))
      :ok = Context.set_custom_assignment(unkeyed, "exp_sb", 2)
      assert Context.treatment(unkeyed, "exp_sb") == 0
    end

    # unitExperimentsIgnoreClusterFields
    test "unit experiments ignore cluster fields", %{clock: clock} do
      for type <- ["unit", nil] do
        unit =
          attribute_switchback("city", %{
            "randomizationType" => type,
            "switchbackClusters" => clusters([{@user, "city"}, {@store, "'x"}]),
            "switchbackClusterValues" => ["nothing"],
            "switchbackPeriodMs" => 0,
            "assignmentRules" =>
              ~s({"rules":[{"type":"split","environments":[],"percentages":"34/33/33"}]})
          })

        reference =
          Map.take(unit, ~w(id name unitType iteration seedHi seedLo split trafficSeedHi
                            trafficSeedLo trafficSplit applications variants randomizationType
                            assignmentRules))

        [published, expected] =
          for experiment <- [unit, reference] do
            set(clock, @anchor - @hour)
            {ctx, events} = ctx(clock, experiment, %{@store => @uid, @user => "u"})
            :ok = Context.set_attribute(ctx, "city", "Lisboa")
            first = Context.treatment(ctx, "exp_sb")

            for i <- 1..5 do
              set(clock, @anchor - @hour + i * @hour)
              assert Context.treatment(ctx, "exp_sb") == first
            end

            publish_exposures(ctx, events)
          end

        assert [%{"eligible" => true, "ruleOverride" => true, "exposedAt" => at}] = published
        assert at == @anchor - @hour
        assert published == expected
      end
    end
  end

  describe "ContextSwitchbackClusterRuleTest" do
    # NOW is inside period 5.
    @period 5
    @now @anchor + 5 * @hour + 17 * 60_000
    @rule_seed_hi 0x1234
    @rule_seed_lo 0x5678ABCD
    @rule_seed Bitwise.bor(Bitwise.bsl(@rule_seed_hi, 32), @rule_seed_lo)

    # switchbackClusters in declared (unit type id ascending) order:
    # session_id before user_id.
    @declared [@session, @user, @device]

    defp sbc(links, overrides \\ %{}) do
      ordered = for type <- @declared, {^type, path} <- links, do: {type, path}

      parts = [34, 33, 33]

      %{
        "id" => 900,
        "name" => "sbc",
        "unitType" => @user,
        "iteration" => 1,
        "seedHi" => @rule_seed_hi,
        "seedLo" => @rule_seed_lo,
        "split" => Enum.map(parts, &(&1 / 100)),
        "variants" =>
          for(
            i <- 0..2,
            do: %{"name" => "#{i}", "config" => ~s({"sbc.config":"test config #{i}"})}
          ),
        "trafficSeedHi" => 7,
        "trafficSeedLo" => 11,
        "trafficSplit" => [0.0, 1.0],
        "applications" => [%{"name" => "website"}],
        "randomizationType" => "switchback",
        "switchbackClusters" => if(links == [], do: nil, else: clusters(ordered)),
        "switchbackStartAt" => @anchor,
        "switchbackPeriodMs" => @hour,
        "switchbackDesignType" => "balanced_block"
      }
      |> Map.merge(overrides)
    end

    @default_links [{@user, "profile/store"}, {@session, "session_store"}]

    defp scheduled(key), do: Assigner.assign(key, @period, @rule_seed, 3)

    # Resolves "sbc" (after every other experiment) and reads what the
    # Collector would list: nil when the experiment does not apply.
    defp resolve(clock, experiments, attributes, units) do
      set(clock, @now)
      {ctx, events} = start(clock, units, %{"experiments" => experiments})
      if attributes != %{}, do: :ok = Context.set_attributes(ctx, attributes)

      for %{"name" => name} <- experiments, name != "sbc", do: Context.treatment(ctx, name)
      variant = Context.treatment(ctx, "sbc")
      config = Context.variable_value(ctx, "sbc.config", nil)

      exposures =
        events
        |> Agent.get(&Enum.reverse/1)
        |> Enum.flat_map(fn
          {:exposure, %{name: "sbc"} = e} -> [ABSmartly.Types.Exposure.to_map(e)]
          _ -> []
        end)

      %{slots: slots} = :sys.get_state(ctx).switchback_slots["sbc"]
      [slot] = Map.values(slots)

      if elem(slot.serving, 0) == :absent do
        assert variant == 0
        assert config == nil
        assert exposures == []
        nil
      else
        %{
          unit: slot.unit_type,
          eligible: slot.assignment.eligible,
          silent: slot.silent,
          variant: variant,
          config: config,
          exposures: exposures
        }
      end
    end

    defp sbc_with(clock, attributes, units, links \\ @default_links, overrides \\ %{}),
      do: resolve(clock, [sbc(links, overrides)], attributes, units)

    defp assert_ineligible(
           clock,
           attributes,
           unit,
           units,
           links \\ @default_links,
           overrides \\ %{}
         ) do
      a = sbc_with(clock, attributes, units, links, overrides)
      assert a != nil, inspect(attributes)
      assert a.unit == unit
      refute a.eligible
      assert a.silent
      assert a.variant == 0
      assert a.config == "test config 0"
      assert a.exposures == [], inspect(attributes)
    end

    # missingOrUnreadableClusterConfigurationReturnsOnlyLegacyIneligibleControl
    test "a missing or unreadable cluster map is only a legacy ineligible control", %{
      clock: clock
    } do
      attributes = %{
        "geo" => %{"city" => "Porto"},
        "geo.city" => "Faro",
        "session_store" => "s-1"
      }

      for links <- [
            [],
            [{@session, "'geo"}],
            [{@session, "geo.city"}],
            [{@session, "'geo.city'"}],
            [{@session, ~s("geo.city")}]
          ] do
        # The declared unit (user_id) only identifies an ineligible control.
        assert_ineligible(clock, attributes, @user, %{@session => "x1", @user => "u1"}, links)
        assert sbc_with(clock, attributes, %{@session => "x1"}, links) == nil
      end

      empty = %{"switchbackClusters" => clusters([])}

      assert_ineligible(
        clock,
        attributes,
        @user,
        %{@session => "x1", @user => "u1"},
        @default_links,
        empty
      )

      # A readable map whose only linked type is absent from the context.
      assert sbc_with(clock, %{"session_store" => "s-1"}, %{@session => "x1", @user => "u1"}, [
               {@device, "session_store"}
             ]) == nil
    end

    # trafficUsesServingUidNotExperimentUidInBothRequestOrders
    test "traffic uses the serving uid, not the experiment's", %{clock: clock} do
      split = [0.6, 0.4]

      witnesses =
        Enum.reduce_while(0..999, %{}, fn i, acc ->
          uid = "traffic-#{i}"
          arm = ABSmartly.VariantAssigner.assign(ABSmartly.Utils.hash_unit(uid), split, 7, 11)
          acc = Map.put_new(acc, arm, uid)
          if map_size(acc) == 2, do: {:halt, acc}, else: {:cont, acc}
        end)

      key = "s-18"
      refute scheduled(key) == 0

      ordinary =
        sbc([], %{
          "name" => "ordinary",
          "id" => 901,
          "randomizationType" => nil,
          "split" => [0.5, 0.5]
        })
        |> Map.merge(%{"variants" => [%{"name" => "0"}, %{"name" => "1"}]})

      for serving_eligible <- [false, true] do
        a =
          resolve(
            clock,
            [sbc(@default_links, %{"trafficSplit" => split}), ordinary],
            %{"session_store" => key, "profile" => %{"store" => key}},
            %{
              @session => witnesses[if(serving_eligible, do: 1, else: 0)],
              @user => witnesses[if(serving_eligible, do: 0, else: 1)]
            }
          )

        assert a.unit == @session
        assert a.eligible == serving_eligible
        assert a.variant == if(serving_eligible, do: scheduled(key), else: 0)
        assert [%{"unit" => @session, "eligible" => ^serving_eligible}] = a.exposures
      end
    end

    # oneMatchingUnitServesItsValue
    test "one matching unit serves its value", %{clock: clock} do
      a = sbc_with(clock, %{"profile" => %{"store" => "s-17"}}, %{@user => "u1"})
      assert a.eligible
      assert a.unit == @user
      assert a.variant == scheduled("s-17")
    end

    # strictAudienceMismatchOnAnEligibleClusterIsListedAsControlAndRecorded
    test "a strict mismatch on an eligible cluster is listed as control and recorded", %{
      clock: clock
    } do
      strict = %{"audience" => @gold, "audienceStrict" => true}

      a =
        sbc_with(clock, %{"session_store" => "s-17"}, %{@session => "x1"}, @default_links, strict)

      assert a.unit == @session
      assert a.eligible
      refute a.silent
      assert a.variant == 0
      assert [%{"audienceMismatch" => true, "assigned" => false}] = a.exposures
    end

    # twoAgreeingUnitsServeTheValue
    test "two agreeing units serve the value", %{clock: clock} do
      a =
        sbc_with(
          clock,
          %{"profile" => %{"store" => "s-17"}, "session_store" => "s-17"},
          %{@user => "u1", @session => "x1"}
        )

      assert a.eligible
      assert a.variant == scheduled("s-17")
    end

    # twoDisagreeingUnitsAreIneligible
    test "two disagreeing units are ineligible", %{clock: clock} do
      assert_ineligible(
        clock,
        %{"profile" => %{"store" => "s-17"}, "session_store" => "s-18"},
        @session,
        %{@user => "u1", @session => "x1"}
      )
    end

    # twoUnitsOfOneTypeWithOnePathAgreeOnTheSameValue
    test "a context holds one uid per unit type", %{clock: clock} do
      {ctx, _} = start(clock, %{@session => "x1"}, %{"experiments" => [sbc(@default_links)]})
      assert {:error, _} = Context.set_unit(ctx, @session, "x2")

      a = sbc_with(clock, %{"session_store" => "s-17"}, %{@session => "x1"})
      assert a.eligible
      assert a.variant == scheduled("s-17")
    end

    # noMatchingUnitIsIneligible
    test "no matching unit does not apply", %{clock: clock} do
      assert sbc_with(clock, %{"session_store" => "s-1"}, %{@device => "d1"}) == nil
      assert sbc_with(clock, %{"session_store" => "s-1"}, %{}) == nil
    end

    # matchingUnitWithoutAValueIsIneligible
    test "a matching unit without a value is ineligible", %{clock: clock} do
      assert_ineligible(clock, %{"other" => "s-1"}, @user, %{@user => "u1"})
      assert_ineligible(clock, %{"other" => "s-1"}, @session, %{@user => "u1", @session => "x1"})
    end

    # nonStringNonIntegerValuesAreIneligible
    test "non-string, non-integer values are ineligible", %{clock: clock} do
      for value <- [1.5, 3.0, true, %{"a" => 1}, ["a"], ""] do
        assert_ineligible(clock, %{"session_store" => value}, @session, %{@session => "x1"})
      end
    end

    # wholeNumbersAreKeyedByTheirDecimalText
    test "whole numbers are keyed by their decimal text", %{clock: clock} do
      refute scheduled("17") == 0
      a = sbc_with(clock, %{"session_store" => 17}, %{@session => "x1"})
      assert a.eligible
      assert a.variant == scheduled("17")

      agree =
        sbc_with(clock, %{"session_store" => 17, "profile" => %{"store" => "17"}}, %{
          @session => "x1",
          @user => "u1"
        })

      assert agree.eligible
    end

    # nestedAndArrayPathsAreRead
    test "nested and array paths are read", %{clock: clock} do
      a =
        sbc_with(
          clock,
          %{"items" => [%{"store" => "a"}, %{"store" => "b"}]},
          %{@session => "x1"},
          [{@session, "items/1/store"}]
        )

      assert a.variant == scheduled("b")
      refute scheduled("a") == scheduled("b")
    end

    # exposureUnitIsTheFirstMatchingUnitInDeclaredOrderWhateverTheRequestOrder
    test "the exposure unit is the first matching unit in declared order", %{clock: clock} do
      key = "s-18"
      refute scheduled(key) == 0

      a =
        sbc_with(clock, %{"profile" => %{"store" => key}, "session_store" => key}, %{
          @user => "u1",
          @session => "x1"
        })

      assert a.unit == @session
      assert [%{"unit" => @session}] = a.exposures
      assert a.variant == scheduled(key)
    end

    # ineligibleClusterNeverPublishesAnExposure
    test "an ineligible cluster never publishes an exposure", %{clock: clock} do
      {ctx, events} =
        start(clock, %{@user => "u1", @session => "x1"}, %{"experiments" => [sbc(@default_links)]})

      :ok = Context.set_attributes(ctx, %{"session_store" => "a", "profile" => %{"store" => "b"}})
      assert Context.treatment(ctx, "sbc") == 0
      assert Context.pending(ctx) == 0
      assert publish_events(ctx, events) == []
    end

    # aUnitWithoutAValueDoesNotServeEvenIfFirstInDeclaredOrder
    test "a unit without a value does not serve even if first in declared order", %{clock: clock} do
      key = "s-17"
      refute scheduled(key) == 0
      a = sbc_with(clock, %{"profile" => %{"store" => key}}, %{@session => "x1", @user => "u1"})
      assert a.unit == @user
      assert [%{"unit" => @user}] = a.exposures
      assert a.variant == scheduled(key)
    end

    # valueNotInTheFilterIsIneligible
    test "a value not in the filter is ineligible", %{clock: clock} do
      filter = %{"switchbackClusterValues" => ["s-1", "s-2"]}

      assert_ineligible(
        clock,
        %{"session_store" => "s-3"},
        @session,
        %{@session => "x1"},
        @default_links,
        filter
      )

      a =
        sbc_with(clock, %{"session_store" => "s-2"}, %{@session => "x1"}, @default_links, filter)

      assert a.eligible
      assert a.variant == scheduled("s-2")
    end

    # nullFilterAssignsEveryValue
    test "a null filter assigns every value", %{clock: clock} do
      for i <- 0..19 do
        a = sbc_with(clock, %{"session_store" => "s-#{i}"}, %{@session => "x1"})
        assert a.eligible
        assert a.variant == scheduled("s-#{i}")
      end
    end

    # validClusterWithoutLinkedRequestUnitDoesNotFallBackToExperimentUnit
    test "a valid cluster without a linked unit does not fall back to unitType", %{clock: clock} do
      links = [{@session, "session_store"}]
      key = "s-17"
      refute scheduled(key) == 0
      attributes = %{"session_store" => key, "profile" => %{"store" => key}}
      assert sbc_with(clock, attributes, %{@user => "u1"}, links) == nil

      linked =
        sbc_with(clock, %{"session_store" => key}, %{@user => "u1", @session => "x1"}, links)

      assert linked.unit == @session
      assert linked.variant == scheduled(key)
    end

    # contextMatchesTheSdkSwitchbackWireRuleParityGrid: the Collector's wire
    # rule (SdkSwitchbackRule), transcribed. It shares the assigner with the
    # SDK, so it checks the wire rule, not the assigner.
    defp oracle(experiment, uid, key, now) do
      start = experiment["switchbackStartAt"]
      period = experiment["switchbackPeriodMs"]
      anchor = -Integer.floor_div(-start, @hour) * @hour

      cond do
        key == nil or now < anchor ->
          {0, false}

        ABSmartly.VariantAssigner.assign(
          ABSmartly.Utils.hash_unit(uid),
          experiment["trafficSplit"],
          7,
          11
        ) !=
            1 ->
          {0, false}

        true ->
          {Assigner.assign(key, Integer.floor_div(now - anchor, period), @rule_seed, 3), true}
      end
    end

    defp grid_context(clock, experiment, cluster, uid, key) do
      {links, attributes, units, overrides} =
        case cluster do
          :disagreeing_second_source ->
            {[{@session, "session_store"}, {@user, "profile/store"}],
             %{"session_store" => key, "profile" => %{"store" => key <> "-other"}},
             %{@session => uid, @user => "u-" <> uid}, %{}}

          :missing_value ->
            {[{@session, "session_store"}], %{"other" => key}, %{@session => uid}, %{}}

          :filtered_value ->
            {[{@session, "session_store"}], %{"session_store" => key}, %{@session => uid},
             %{"switchbackClusterValues" => [key <> "-allowed"]}}

          :single ->
            {[{@session, "session_store"}], %{"session_store" => key}, %{@session => uid}, %{}}
        end

      experiment =
        Map.merge(experiment, Map.put(overrides, "switchbackClusters", clusters(links)))

      now = read(clock)
      set(clock, @anchor - 10 * @hour)
      {ctx, events} = start(clock, units, %{"experiments" => [experiment]})
      :ok = Context.set_attributes(ctx, attributes)
      set(clock, now)
      {ctx, events}
    end

    test "the context matches the Collector's wire-rule parity grid", %{clock: clock} do
      counts =
        for cluster <- [:single, :disagreeing_second_source, :missing_value, :filtered_value],
            anchor <- [@anchor, @anchor + 7 * @hour],
            period_ms <- [@hour, 2 * @hour, 24 * @hour],
            u <- 0..5,
            key <- ["s-1", "s-2", "42", "Lisboa"],
            now <- [
              anchor - @hour,
              anchor - 1,
              anchor,
              anchor + period_ms - 1,
              anchor + period_ms,
              anchor + 3 * period_ms + 5,
              anchor + 11 * period_ms
            ],
            reduce: %{eligible: 0, ineligible: 0, misses: 0} do
          acc ->
            experiment =
              sbc(@default_links, %{
                "trafficSplit" => [0.3, 0.7],
                "switchbackStartAt" => anchor,
                "switchbackPeriodMs" => period_ms
              })

            uid = "uid-#{u}"
            set(clock, now)
            oracle_key = if cluster == :single, do: key
            {variant, eligible} = oracle(experiment, uid, oracle_key, now)
            {ctx, events} = grid_context(clock, experiment, cluster, uid, key)
            message = inspect({cluster, anchor, period_ms, uid, key, now})
            assert Context.treatment(ctx, "sbc") == variant, message

            exposures =
              for {:exposure, %{name: "sbc"} = e} <- Agent.get(events, &Enum.reverse/1), do: e

            expected_count = if oracle_key != nil and now >= anchor, do: 1, else: 0
            assert length(exposures) == expected_count, message
            if expected_count == 1, do: assert(hd(exposures).eligible == eligible, message)
            GenServer.stop(ctx)

            cond do
              cluster != :single -> acc
              eligible -> %{acc | eligible: acc.eligible + 1}
              now >= anchor -> %{acc | ineligible: acc.ineligible + 1, misses: acc.misses + 1}
              true -> %{acc | ineligible: acc.ineligible + 1}
            end
        end

      assert counts.eligible > 100
      assert counts.ineligible > 100
      assert counts.misses > 0

      # The deliberate divergence: an anchor off the hour is unservable,
      # while the transcribed oracle re-ceils it and draws.
      unaligned =
        sbc(@default_links, %{
          "switchbackStartAt" => @anchor + 7 * @hour + 1,
          "switchbackPeriodMs" => @hour
        })

      set(clock, @anchor + 8 * @hour + 5)
      assert {_, true} = oracle(unaligned, "uid-0", "s-1", read(clock))
      {ctx, events} = grid_context(clock, unaligned, :single, "uid-0", "s-1")
      assert Context.treatment(ctx, "sbc") == 0
      assert Context.pending(ctx) == 0
      assert for({:exposure, _} = e <- Agent.get(events, & &1), do: e) == []
    end
  end

  describe "SwitchbackServerParityTest" do
    @parity_seed 1_234_567_890_123
    @periods 4
    @two_sources [{@store, "store_city"}, {@device, "geo/city"}]

    defp parity_experiment(clusters, values \\ nil, seed \\ @parity_seed) do
      import Bitwise

      experiment(clusters(clusters), %{
        "unitType" => @user,
        "seedHi" => seed >>> 32,
        "seedLo" =>
          band(seed, 0xFFFFFFFF) |> then(&if(&1 >= 0x80000000, do: &1 - 0x100000000, else: &1)),
        "variants" => for(i <- 0..2, do: %{"name" => "#{i}", "config" => nil}),
        "switchbackClusterValues" => values
      })
    end

    defp two_units, do: %{@store => "s1", @device => "d1"}

    defp serve(clock, experiment, units, attributes) do
      set(clock, @anchor)
      {ctx, events} = start(clock, units, %{"experiments" => [experiment]})
      if attributes, do: :ok = Context.set_attributes(ctx, attributes)

      variants =
        for p <- 0..(@periods - 1) do
          set(clock, @anchor + p * @hour + 1)
          Context.treatment(ctx, "exp_sb")
        end

      {variants, for({:exposure, e} <- Agent.get(events, &Enum.reverse/1), do: e)}
    end

    defp collector_variant(key, period), do: Assigner.assign(key, period, @parity_seed, @arms)

    defp assert_eligible({variants, exposures}, serving, key, message) do
      assert length(exposures) == @periods, message

      for p <- 0..(@periods - 1) do
        expected = collector_variant(key, p)
        assert Enum.at(variants, p) == expected, "#{message} period #{p}"
        e = Enum.at(exposures, p)

        assert {e.unit, e.variant, e.assigned, e.eligible, e.exposed_at} ==
                 {serving, expected, true, true, @anchor + p * @hour + 1},
               message
      end
    end

    defp assert_silent_control({variants, exposures}, message) do
      assert variants == List.duplicate(0, @periods), message
      assert exposures == [], message
    end

    # rawKeySchedulesMatchTheIndependentReference
    test "raw key schedules match the independent reference", %{clock: clock} do
      assert_eligible(
        serve(clock, parity_experiment([{@store, "city"}]), %{@store => "s1"}, %{
          "city" => "Lisboa"
        }),
        @store,
        "Lisboa",
        "Lisboa"
      )

      assert Enum.map(0..3, &collector_variant("Lisboa", &1)) == [0, 1, 2, 2]
      assert Enum.map(0..3, &collector_variant("Porto", &1)) == [2, 1, 0, 1]
      assert Enum.map(0..3, &collector_variant("42", &1)) == [0, 2, 1, 2]
    end

    # agreementServesTheFirstSourceUnit
    test "agreement serves the first source's unit", %{clock: clock} do
      assert_eligible(
        serve(clock, parity_experiment(@two_sources), two_units(), %{
          "store_city" => "Lisboa",
          "geo" => %{"city" => "Lisboa"}
        }),
        @store,
        "Lisboa",
        "agreement"
      )
    end

    # disagreementIsIneligibleAndRecordsNothing
    test "disagreement is ineligible and records nothing", %{clock: clock} do
      assert_silent_control(
        serve(clock, parity_experiment(@two_sources), two_units(), %{
          "store_city" => "Lisboa",
          "geo" => %{"city" => "Porto"}
        }),
        "disagreement"
      )
    end

    # missingValueIsSkippedAndTheNextValueServes
    test "a missing value is skipped and the next value serves", %{clock: clock} do
      exp = parity_experiment(@two_sources)

      assert_eligible(
        serve(clock, exp, two_units(), %{"geo" => %{"city" => "Porto"}}),
        @device,
        "Porto",
        "first"
      )

      assert_eligible(
        serve(clock, exp, two_units(), %{"store_city" => "Porto"}),
        @store,
        "Porto",
        "second"
      )

      assert_silent_control(serve(clock, exp, two_units(), %{"other" => "x"}), "no value")
      assert_silent_control(serve(clock, exp, two_units(), nil), "no attributes")
    end

    # onlyLinkedUnitsPresentInTheContextTakePart
    test "only linked units present in the context take part", %{clock: clock} do
      assert_eligible(
        serve(clock, parity_experiment(@two_sources), %{@device => "d1"}, %{
          "store_city" => "Lisboa",
          "geo" => %{"city" => "Porto"}
        }),
        @device,
        "Porto",
        "store unit absent"
      )
    end

    # filteredValueIsIneligibleAndAllowedValueServes
    test "a filtered value is ineligible and an allowed value serves", %{clock: clock} do
      lisboa = %{"store_city" => "Lisboa"}

      assert_silent_control(
        serve(clock, parity_experiment(@two_sources, ["Porto", "Faro"]), two_units(), lisboa),
        "filtered"
      )

      for values <- [["Porto", "Lisboa"], nil, []] do
        assert_eligible(
          serve(clock, parity_experiment(@two_sources, values), two_units(), lisboa),
          @store,
          "Lisboa",
          inspect(values)
        )
      end

      # The filter compares the normalised text of numeric values.
      assert_eligible(
        serve(clock, parity_experiment(@two_sources, ["42"]), two_units(), %{"store_city" => 42}),
        @store,
        "42",
        "numeric filter"
      )

      # A filtered first value is not replaced by a later allowed one.
      assert_silent_control(
        serve(clock, parity_experiment(@two_sources, ["Porto"]), two_units(), %{
          "store_city" => "Lisboa",
          "geo" => %{"city" => "Porto"}
        }),
        "filtered first value"
      )
    end

    # lowerUnitTypeIdSourceServesFirst
    test "the first declared source serves first", %{clock: clock} do
      agreeing = %{"store_city" => "Lisboa", "geo" => %{"city" => "Lisboa"}}

      assert_eligible(
        serve(clock, parity_experiment(Enum.reverse(@two_sources)), two_units(), agreeing),
        @device,
        "Lisboa",
        "device first"
      )

      assert_eligible(
        serve(clock, parity_experiment(@two_sources), two_units(), agreeing),
        @store,
        "Lisboa",
        "store first"
      )
    end

    # nonKeyValuesAreIgnored
    test "non-key values are skipped, never a disagreement", %{clock: clock} do
      for value <- [true, false, 1.5, 2.0, %{"a" => "b"}, ["x"], [], nil, ""] do
        assert_eligible(
          serve(clock, parity_experiment(@two_sources), two_units(), %{
            "store_city" => value,
            "geo" => %{"city" => "Porto"}
          }),
          @device,
          "Porto",
          inspect(value)
        )

        assert_silent_control(
          serve(clock, parity_experiment([{@store, "store_city"}]), %{@store => "s1"}, %{
            "store_city" => value
          }),
          "#{inspect(value)} alone"
        )
      end
    end

    # numericValuesAreKeyedAsText
    test "numeric values are keyed as text", %{clock: clock} do
      for store <- [42, "42"], device <- [42, "42"] do
        assert_eligible(
          serve(clock, parity_experiment(@two_sources), two_units(), %{
            "store_city" => store,
            "geo" => %{"city" => device}
          }),
          @store,
          "42",
          inspect({store, device})
        )
      end

      big = 123_456_789_012_345_678_901_234_567_890

      assert_eligible(
        serve(clock, parity_experiment([{@store, "n"}]), %{@store => "s1"}, %{"n" => big}),
        @store,
        "123456789012345678901234567890",
        "big integer"
      )

      assert_eligible(
        serve(clock, parity_experiment([{@store, "n"}]), %{@store => "s1"}, %{"n" => -7}),
        @store,
        "-7",
        "negative"
      )

      assert_silent_control(
        serve(clock, parity_experiment(@two_sources), two_units(), %{
          "store_city" => 42,
          "geo" => %{"city" => "042"}
        }),
        "42 vs 042"
      )
    end

    # malformedPathsAreUnservable
    test "malformed paths are unservable", %{clock: clock} do
      attributes = %{
        "store_city" => "Lisboa",
        "geo" => %{"city" => "Porto"},
        "geo.city" => "Faro"
      }

      for path <- [
            "'geo/city",
            ~s("geo),
            "geo/'city",
            "geo.city",
            "geo/a.b",
            "'geo.city'",
            ~s("geo.city")
          ] do
        assert_silent_control(
          serve(
            clock,
            parity_experiment([{@store, "store_city"}, {@device, path}]),
            two_units(),
            attributes
          ),
          path
        )

        assert_silent_control(
          serve(clock, parity_experiment([{@device, path}]), two_units(), attributes),
          path
        )
      end
    end

    # noLinkedUnitIsAbsent
    test "no linked unit is absent", %{clock: clock} do
      assert_silent_control(
        serve(clock, parity_experiment(@two_sources), %{@user => "u1"}, %{
          "store_city" => "Lisboa"
        }),
        "no linked unit"
      )
    end

    # trafficFollowsTheServingUnitHash
    test "traffic follows the serving unit's hash", %{clock: clock} do
      results =
        for u <- 0..23 do
          traffic = %{"trafficSplit" => [0.5, 0.5], "trafficSeedHi" => 3, "trafficSeedLo" => 4}
          switchback = Map.merge(parity_experiment(@two_sources), traffic)

          twin =
            Map.merge(switchback, %{
              "name" => "exp_unit",
              "id" => 2,
              "randomizationType" => nil,
              "unitType" => @device
            })

          set(clock, @anchor)

          {ctx, events} =
            start(clock, %{@store => "s1", @device => "device-#{u}"}, %{
              "experiments" => [switchback, twin]
            })

          :ok = Context.set_attribute(ctx, "geo", %{"city" => "Porto"})
          Context.treatment(ctx, "exp_unit")

          for p <- 0..(@periods - 1) do
            set(clock, @anchor + p * @hour)
            Context.treatment(ctx, "exp_sb")
          end

          [twin_exposure | exposures] =
            for {:exposure, e} <- Agent.get(events, &Enum.reverse/1), do: e

          for {e, p} <- Enum.with_index(exposures) do
            assert e.unit == @device
            assert e.eligible == twin_exposure.eligible

            assert e.variant ==
                     if(twin_exposure.eligible, do: collector_variant("Porto", p), else: 0)
          end

          twin_exposure.eligible
        end

      assert true in results and false in results
    end

    # attributePathCasesMatchTheCollector
    test "attribute path cases match the Collector", %{clock: clock} do
      fixture =
        Path.expand("../../fixtures/switchback/attribute-path-cases.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()

      eligible =
        Enum.count(fixture["cases"], fn c ->
          served =
            serve(
              clock,
              parity_experiment([{@store, c["path"]}]),
              %{@store => "s1"},
              fixture["attributes"]
            )

          if c["supported"] and c["value"] != nil do
            assert_eligible(served, @store, c["value"], inspect(c))
            true
          else
            assert_silent_control(served, inspect(c))
            false
          end
        end)

      assert eligible == 3
    end

    test "attribute names are trimmed of control characters only, as Java's trim", %{clock: clock} do
      exp = parity_experiment([{@store, "cluster"}])

      assert_eligible(
        serve(clock, exp, %{@store => "s1"}, %{"\t cluster\n" => "Porto"}),
        @store,
        "Porto",
        "controls"
      )

      # A leading combining mark is part of the name, not trimmed with it.
      combining = parity_experiment([{@store, "\u0301city"}])

      assert_eligible(
        serve(clock, combining, %{@store => "s1"}, %{" \u0301city" => "Porto"}),
        @store,
        "Porto",
        "mark"
      )

      # U+00A0 is not trimmed, so the name does not match.
      assert_silent_control(
        serve(clock, exp, %{@store => "s1"}, %{"\u00A0cluster" => "Porto"}),
        "nbsp"
      )
    end

    # repeatedAttributeNamesResolveToTheLatest
    test "repeated attribute names resolve to the latest, names trimmed", %{clock: clock} do
      assert_eligible(
        serve(clock, parity_experiment([{@store, "cluster"}]), %{@store => "s1"}, %{
          " cluster " => "Porto"
        }),
        @store,
        "Porto",
        "trimmed name"
      )

      set(clock, @anchor)

      {ctx, events} =
        start(clock, %{@store => "s1"}, %{
          "experiments" => [parity_experiment([{@store, "cluster"}])]
        })

      :ok = Context.set_attribute(ctx, "cluster", "Lisboa")
      :ok = Context.set_attribute(ctx, "cluster", "Porto")
      set(clock, @anchor + 1)
      assert Context.treatment(ctx, "exp_sb") == collector_variant("Porto", 0)
      assert [%{eligible: true}] = for({:exposure, e} <- Agent.get(events, & &1), do: e)
    end
  end
end
