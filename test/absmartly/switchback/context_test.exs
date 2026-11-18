defmodule ABSmartly.Switchback.ContextTest do
  @moduledoc """
  Port of the Java SDK's `ContextSwitchbackTest` (java-sdk#15). Each test
  names the Java test it ports. The Java tests that reach into JVM internals
  (lock re-entrancy from a refreshing audience matcher, concurrent
  resolution of one period) protect behaviour a GenServer has by
  construction, since every call runs to completion before the next starts;
  they are ported as the sequential behaviour they protect.
  """

  use ExUnit.Case, async: true

  import ABSmartly.SwitchbackTestSupport

  alias ABSmartly.Context
  alias ABSmartly.Switchback.Assigner

  @unit_type "store_id"
  @uid "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
  @uid_hash "pAE3a1i5Drs5mKRNq56adA"
  @hour 3_600_000
  @day 24 * @hour
  @anchor 1_767_225_600_000
  @seed_hi -5
  @seed_lo -7
  @seed Bitwise.bor(Bitwise.bsl(@seed_hi, 32), Bitwise.band(@seed_lo, 0xFFFFFFFF))

  @cluster_path "store_key"
  @cluster_key "store-42"
  # Periods 0..11 of the raw cluster key "store-42" (Java's independent
  # Python reference).
  @expected_2 [0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 0, 1]
  @expected_3 [0, 2, 1, 2, 1, 0, 1, 2, 0, 1, 0, 2]
  @expected_10 [8, 3, 7, 4, 2, 0, 5, 1, 9, 6, 3, 7]
  # What keying by the unit's hash or the raw uid would serve.
  @uid_hash_3 [1, 2, 0, 2, 1, 0, 2, 0, 1, 1, 2, 0]
  @uid_3 [2, 0, 1, 0, 1, 2, 1, 2, 0, 0, 1, 2]

  @strict_gold ~s({"filter":[{"eq":[{"var":"tier"},{"value":"gold"}]}]})
  @assign_1 ~s({"rules":[{"type":"assign","environments":[],"variant":1}]})
  @assign_2 ~s({"rules":[{"type":"assign","environments":[],"variant":2}]})

  defp e2(i), do: Enum.at(@expected_2, i)
  defp e3(i), do: Enum.at(@expected_3, i)

  # The default switchback: id 1, "exp_sb".
  def sb(arms, period_ms, overrides \\ %{}),
    do: switchback(1, "exp_sb", arms, period_ms, overrides)

  def switchback(id, name, arms, period_ms, overrides \\ %{}) do
    %{
      "id" => id,
      "name" => name,
      "unitType" => @unit_type,
      "iteration" => 1,
      "seedHi" => @seed_hi,
      "seedLo" => @seed_lo,
      "split" => List.duplicate(1.0 / arms, arms),
      "variants" =>
        for(i <- 0..(arms - 1), do: %{"name" => <<?A + i>>, "config" => ~s({"sb.arm":#{i}})}),
      "trafficSeedHi" => 1,
      "trafficSeedLo" => 2,
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => 0,
      "applications" => [%{"name" => "website"}],
      "audienceStrict" => false,
      "randomizationType" => "switchback",
      "switchbackClusters" => clusters([{@unit_type, @cluster_path}]),
      "switchbackStartAt" => @anchor,
      "switchbackPeriodMs" => period_ms,
      "switchbackCarryoverDurationMs" => 0,
      "switchbackBurnInDurationMs" => 0,
      "switchbackBurnOutDurationMs" => 0,
      "switchbackDesignType" => "balanced_block",
      "switchbackEstimand" => "global_average_treatment_effect"
    }
    |> Map.merge(overrides)
  end

  defp as_unit(experiment),
    do:
      Map.merge(experiment, %{
        "randomizationType" => nil,
        "switchbackClusters" => nil,
        "switchbackStartAt" => nil,
        "switchbackPeriodMs" => nil
      })

  defp data(experiments, holdouts \\ []),
    do: %{"experiments" => List.wrap(experiments), "holdouts" => holdouts}

  defp holdout(split) do
    %{
      "id" => 11,
      "name" => "holdout_a",
      "unitType" => @unit_type,
      "iteration" => 1,
      "seedHi" => 13,
      "seedLo" => 111,
      "split" => split,
      "trafficSplit" => [0.0, 1.0]
    }
  end

  defp create(clock, payload, units \\ %{@unit_type => @uid}) do
    start(clock, units, payload, attributes: %{@cluster_path => @cluster_key})
  end

  defp exposure(id, name, variant, exposed_at, assigned, eligible, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "unit" => @unit_type,
        "variant" => variant,
        "exposedAt" => exposed_at,
        "assigned" => assigned,
        "eligible" => eligible,
        "overridden" => false,
        "fullOn" => false,
        "custom" => false,
        "audienceMismatch" => false,
        "ruleOverride" => false
      },
      extra
    )
  end

  defp rule_exposure(name, variant, at),
    do: exposure(1, name, variant, at, false, true, %{"ruleOverride" => true})

  defp strict_mismatch_exposure(at),
    do: exposure(1, "exp_sb", 0, at, false, true, %{"audienceMismatch" => true})

  defp peek_schedule(ctx, clock, name, period_ms, periods) do
    for i <- 0..(periods - 1) do
      set(clock, @anchor + i * period_ms)
      Context.peek(ctx, name)
    end
  end

  setup do
    {:ok, clock: clock(@anchor)}
  end

  # clusterIdentityIsTheRawClusterValue
  test "the cluster identity is the raw cluster value", %{clock: clock} do
    assert ABSmartly.Utils.hash_unit(@uid) == @uid_hash
    {ctx, _} = create(clock, data(sb(3, @hour)))
    served = peek_schedule(ctx, clock, "exp_sb", @hour, 12)

    assert served == @expected_3
    refute served == @uid_hash_3
    refute served == @uid_3
    hashed_key = ABSmartly.Utils.hash_unit(@cluster_key)

    for i <- 0..11, do: assert(Assigner.assign(@cluster_key, i, @seed, 3) == Enum.at(served, i))
    assert Enum.any?(0..11, &(Assigner.assign(hashed_key, &1, @seed, 3) != Enum.at(served, &1)))
  end

  # servesTwoThreeAndTenArmPermutations
  test "serves two, three and ten arm permutations", %{clock: clock} do
    {ctx, _} =
      create(
        clock,
        data([
          switchback(1, "exp_2", 2, @hour),
          switchback(2, "exp_3", 3, @hour),
          switchback(3, "exp_10", 10, @hour)
        ])
      )

    assert peek_schedule(ctx, clock, "exp_2", @hour, 12) == @expected_2
    assert peek_schedule(ctx, clock, "exp_3", @hour, 12) == @expected_3
    assert peek_schedule(ctx, clock, "exp_10", @hour, 12) == @expected_10
  end

  # oneHourBoundaryAtExactEdgeMilliseconds
  test "one-hour boundary at the exact edge milliseconds", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))

    for {now, expected} <- [
          {@anchor - 1, 0},
          {@anchor, e2(0)},
          {@anchor + @hour - 1, e2(0)},
          {@anchor + @hour, e2(1)},
          {@anchor + 3 * @hour - 1, e2(2)},
          {@anchor + 3 * @hour, e2(3)}
        ] do
      set(clock, now)
      assert Context.peek(ctx, "exp_sb") == expected, "now #{now}"
    end
  end

  # twentyFourHourBoundaryAtExactEdgeMilliseconds
  test "24-hour boundary at the exact edge milliseconds", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @day)))

    for {now, expected} <- [
          {@anchor - 1, 0},
          {@anchor, e2(0)},
          {@anchor + @hour, e2(0)},
          {@anchor + @day - 1, e2(0)},
          {@anchor + @day, e2(1)},
          {@anchor + 4 * @day - 1, e2(3)},
          {@anchor + 4 * @day, e2(4)}
        ] do
      set(clock, now)
      assert Context.peek(ctx, "exp_sb") == expected, "now #{now}"
    end
  end

  # unalignedStartIsUnservableAndPreAnchorIsIneligible
  test "an unaligned start is unservable and pre-anchor is ineligible", %{clock: clock} do
    start = @anchor + 1_234_567

    {ctx, events} =
      create(
        clock,
        data([
          switchback(1, "exp_aligned", 2, @hour, %{"switchbackStartAt" => @anchor + @hour}),
          switchback(2, "exp_unaligned", 2, @hour, %{"switchbackStartAt" => start})
        ])
      )

    for now <- [@anchor, start - 1, start, @anchor + @hour - 1] do
      set(clock, now)
      assert Context.treatment(ctx, "exp_aligned") == 0
      assert Context.treatment(ctx, "exp_unaligned") == 0
    end

    assert Context.pending(ctx) == 0

    for i <- 1..3 do
      set(clock, @anchor + i * @hour)
      assert Context.treatment(ctx, "exp_aligned") == e2(i - 1)
      assert Context.treatment(ctx, "exp_unaligned") == 0
      set(clock, start + i * @hour)
      assert Context.treatment(ctx, "exp_unaligned") == 0
    end

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_aligned", e2(0), @anchor + @hour, true, true),
             exposure(1, "exp_aligned", e2(1), @anchor + 2 * @hour, true, true),
             exposure(1, "exp_aligned", e2(2), @anchor + 3 * @hour, true, true)
           ]
  end

  # anchorNotOnAnHourBoundaryIsUnservableOnGetAndPost
  test "an anchor off the hour or out of range is unservable", %{clock: clock} do
    max_anchor = 253_402_300_800_000
    long_max = 0x7FFFFFFFFFFFFFFF

    for start_at <- [
          @anchor + 1,
          @anchor - 1,
          @anchor + 30 * 60_000,
          @anchor + @hour - 1,
          -@hour,
          -1,
          max_anchor,
          max_anchor + @hour,
          long_max - rem(long_max, @hour)
        ] do
      set(clock, 0)
      {ctx, events} = create(clock, data(sb(2, @hour, %{"switchbackStartAt" => start_at})))

      # Java's long wraps start_at + @hour for the last anchor; the clock
      # is a long, so that reading is left out here.
      for now <- [
            0,
            @anchor,
            @anchor + 2 * @hour + 1,
            start_at,
            start_at + @hour,
            max_anchor + @day
          ],
          now <= long_max do
        set(clock, now)
        assert Context.treatment(ctx, "exp_sb") == 0, "startAt #{start_at} now #{now}"
        assert Context.variable_value(ctx, "sb.arm", -1) == 0
      end

      assert Context.pending(ctx) == 0
      assert publish_events(ctx, events) == []
    end

    for start_at <- [0, @anchor, max_anchor - @hour] do
      set(clock, start_at + @hour)
      {ctx, _} = create(clock, data(sb(2, @hour, %{"switchbackStartAt" => start_at})))
      assert Context.treatment(ctx, "exp_sb") == e2(1), "startAt #{start_at}"
      assert Context.pending(ctx) == 1
    end
  end

  # nullStartAtIsIneligibleAndNeverFallsBackToUnitAssignment
  test "a null start is ineligible and never falls back to unit assignment", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour, %{"switchbackStartAt" => nil})))

    for i <- 0..3 do
      set(clock, @anchor + i * @hour)
      assert Context.treatment(ctx, "exp_sb") == 0
      assert Context.variable_value(ctx, "sb.arm", -1) == 0
    end

    assert Context.pending(ctx) == 0
  end

  # samePeriodIsCachedAndNextPeriodRollsOverWithOneExposureEach
  test "the same period is cached and the next rolls over, one exposure each", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour)))

    set(clock, @anchor + 10)
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 1
    set(clock, @anchor + @hour - 1)
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.peek(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 1

    set(clock, @anchor + @hour)
    assert Context.peek(ctx, "exp_sb") == e2(1)
    assert Context.pending(ctx) == 1
    assert Context.treatment(ctx, "exp_sb") == e2(1)
    assert Context.pending(ctx) == 2
    set(clock, @anchor + @hour + 30 * 60_000)
    assert Context.treatment(ctx, "exp_sb") == e2(1)
    assert Context.pending(ctx) == 2

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", e2(0), @anchor + 10, true, true),
             exposure(1, "exp_sb", e2(1), @anchor + @hour, true, true)
           ]
  end

  # variableLookupsFollowThePeriodAndExposeOncePerPeriod
  test "variable lookups follow the period and expose once per period", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(3, @hour)))
    assert Context.variable_keys(ctx) == %{"sb.arm" => ["exp_sb"]}
    assert Context.experiments(ctx) == ["exp_sb"]

    for i <- 0..2 do
      set(clock, @anchor + i * @hour)
      assert Context.peek_variable_value(ctx, "sb.arm", -1) == e3(i)
      assert Context.variable_value(ctx, "sb.arm", -1) == e3(i)
      assert Context.variable_value(ctx, "sb.arm", -1) == e3(i)
      assert Context.treatment(ctx, "exp_sb") == e3(i)
    end

    assert Context.pending(ctx) == 3
  end

  # missingClusterUnitIsUnassignedWithoutFallback
  test "a missing cluster unit is unassigned, with no fallback", %{clock: clock} do
    {ctx, events} =
      create(clock, data(sb(2, @hour, %{"unitType" => "user_id"})), %{"user_id" => @uid})

    for i <- 0..2 do
      set(clock, @anchor + i * @hour)
      assert Context.peek(ctx, "exp_sb") == 0
      assert Context.treatment(ctx, "exp_sb") == 0
      assert Context.variable_value(ctx, "sb.arm", -1) == -1
    end

    assert Context.pending(ctx) == 0

    :ok = Context.set_unit(ctx, @unit_type, @uid)
    assert Context.treatment(ctx, "exp_sb") == e2(2)

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", e2(2), @anchor + 2 * @hour, true, true)
           ]
  end

  # fullOnServesTheFullOnVariantInEveryPeriod
  test "full-on serves the full-on variant in every period", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(3, @hour, %{"fullOnVariant" => 2})))

    for i <- 0..3 do
      set(clock, @anchor + i * @hour)
      assert Context.treatment(ctx, "exp_sb") == 2
    end

    exposures = publish_exposures(ctx, events)
    assert length(exposures) == 4
    assert Enum.all?(exposures, &(&1["variant"] == 2 and &1["fullOn"]))
  end

  # overrideAndCustomAssignmentWinInEveryPeriod
  test "override and custom assignment win in every period", %{clock: clock} do
    {ctx, events} =
      create(
        clock,
        data([switchback(1, "exp_override", 3, @hour), switchback(2, "exp_custom", 3, @hour)])
      )

    :ok = Context.set_override(ctx, "exp_override", 7)
    :ok = Context.set_custom_assignment(ctx, "exp_custom", 2)

    for i <- 0..2 do
      set(clock, @anchor + i * @hour)
      assert Context.treatment(ctx, "exp_override") == 7
      assert Context.treatment(ctx, "exp_custom") == 2
    end

    exposures = publish_exposures(ctx, events)
    assert length(exposures) == 6

    for e <- exposures do
      if e["name"] == "exp_override",
        do: assert(e["overridden"] and e["variant"] == 7),
        else: assert(e["custom"] and e["variant"] == 2)
    end
  end

  # trafficEligibilityIsClusterSticky
  test "traffic eligibility is sticky on the serving unit", %{clock: clock} do
    results =
      for u <- 0..23 do
        sb = switchback(1, "exp_sb", 2, @hour, %{"trafficSplit" => [0.5, 0.5]})

        twin =
          switchback(2, "exp_unit", 2, @hour, %{
            "trafficSplit" => [0.5, 0.5],
            "randomizationType" => nil,
            "switchbackStartAt" => nil
          })

        set(clock, @anchor)
        {ctx, events} = create(clock, data([sb, twin]), %{@unit_type => "store_#{u}"})
        Context.treatment(ctx, "exp_unit")

        for i <- 0..3 do
          set(clock, @anchor + i * @hour)
          Context.treatment(ctx, "exp_sb")
        end

        [twin_exposure | sb_exposures] = publish_exposures(ctx, events)
        assert length(sb_exposures) == 4

        for e <- sb_exposures do
          assert e["name"] == "exp_sb"
          assert e["eligible"] == twin_exposure["eligible"]
          unless twin_exposure["eligible"], do: assert(e["variant"] == 0)
        end

        twin_exposure["eligible"]
      end

    assert true in results and false in results
  end

  # unitExperimentsAreUnaffected
  test "unit experiments are unaffected", %{clock: clock} do
    {ctx, _} =
      create(
        clock,
        data([
          sb(2, @hour, %{"randomizationType" => "unit"}),
          switchback(1, "exp_absent", 2, @hour, %{"randomizationType" => nil})
        ])
      )

    variant = Context.treatment(ctx, "exp_sb")
    absent = Context.treatment(ctx, "exp_absent")

    for i <- 1..5 do
      set(clock, @anchor + i * @hour)
      assert Context.treatment(ctx, "exp_sb") == variant
      assert Context.treatment(ctx, "exp_absent") == absent
    end

    assert Context.pending(ctx) == 2
  end

  defp refresh(ctx, experiments, holdouts \\ []),
    do: :ok = Context.refresh(ctx, context_data(data(experiments, holdouts)))

  # refreshInvalidatesWhenGridFieldsChangeButNotForAnalysisOnlyFields
  test "refresh invalidates on grid fields but not on analysis-only fields", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 10)
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 1

    refresh(ctx, [
      sb(2, @hour, %{
        "switchbackBurnInDurationMs" => 600_000,
        "switchbackBurnOutDurationMs" => 300_000,
        "switchbackCarryoverDurationMs" => 900_000,
        "switchbackEstimand" => "other"
      })
    ])

    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 1

    # Period 0 under both grids, so only the identity can invalidate.
    refresh(ctx, [sb(2, 2 * @hour)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 2

    refresh(ctx, [sb(2, 2 * @hour, %{"switchbackDesignType" => "other_design"})])
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 3

    refresh(ctx, [sb(2, 2 * @hour, %{"randomizationType" => "unit"})])
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 4

    refresh(ctx, [sb(2, 2 * @hour)])
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 5

    path = clusters([{@unit_type, "'store_key'"}])
    refresh(ctx, [sb(2, 2 * @hour, %{"switchbackClusters" => path})])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 6

    link_added = clusters([{@unit_type, "'store_key'"}, {"device_id", "city"}])
    refresh(ctx, [sb(2, 2 * @hour, %{"switchbackClusters" => link_added})])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 7

    reordered = clusters([{"device_id", "city"}, {@unit_type, "'store_key'"}])
    refresh(ctx, [sb(2, 2 * @hour, %{"switchbackClusters" => reordered})])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 8

    values = %{"switchbackClusters" => reordered, "switchbackClusterValues" => [@cluster_key]}
    refresh(ctx, [sb(2, 2 * @hour, values)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 9

    # An unrelated unitType edit is not identity: switchbacks never read it.
    refresh(ctx, [sb(2, 2 * @hour, Map.put(values, "unitType", "anything"))])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 9
  end

  # refreshSettingStartAtStartsTheGrid
  test "a refresh setting the start starts the grid", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour, %{"switchbackStartAt" => nil})))
    set(clock, @anchor + 10)
    assert Context.treatment(ctx, "exp_sb") == 0

    refresh(ctx, [sb(2, @hour)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 1
  end

  # holdoutSuppressionAndExposureSpanPeriods
  test "holdouts never apply to a switchback", %{clock: clock} do
    # split [0.1, 0.9]: arm 0 (held out) for @uid.
    covered = sb(2, @hour, %{"holdoutIds" => [11]})
    {ctx, events} = create(clock, data(covered, [holdout([0.1, 0.9])]))

    for i <- 0..2 do
      set(clock, @anchor + i * @hour)
      assert Context.treatment(ctx, "exp_sb") == e2(i)
      assert Context.variable_value(ctx, "sb.arm", -1) == e2(i)
    end

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", e2(0), @anchor, true, true),
             exposure(1, "exp_sb", e2(1), @anchor + @hour, true, true),
             exposure(1, "exp_sb", e2(2), @anchor + 2 * @hour, true, true)
           ]
  end

  # assignmentRuleOverridesTheSchedule
  test "an assignment rule overrides the schedule, also before the anchor", %{clock: clock} do
    experiment = sb(2, @hour, %{"assignmentRules" => @assign_1})

    for u <- 0..9 do
      set(clock, @anchor - 1)
      {ctx, events} = create(clock, data(experiment), %{@unit_type => "user-#{u}"})
      assert Context.treatment(ctx, "exp_sb") == 1
      assert Context.variable_value(ctx, "sb.arm", -1) == 1

      for i <- 0..3 do
        set(clock, @anchor + i * @hour)
        assert Context.treatment(ctx, "exp_sb") == 1
      end

      assert publish_exposures(ctx, events) ==
               [rule_exposure("exp_sb", 1, @anchor - 1)] ++
                 for(i <- 0..3, do: rule_exposure("exp_sb", 1, @anchor + i * @hour))
    end
  end

  # unservableOnlyReplacesTheVariantDrawNotFullOnOrRules
  test "an unservable schedule only replaces the draw, not full-on or rules", %{clock: clock} do
    {ctx, events} =
      create(
        clock,
        data([
          switchback(1, "sb_full_on", 2, @hour, %{
            "switchbackStartAt" => nil,
            "fullOnVariant" => 1
          }),
          switchback(2, "sb_rules", 2, @hour, %{
            "switchbackPeriodMs" => 0,
            "assignmentRules" => @assign_1
          }),
          switchback(3, "sb_unaligned_rules", 2, @hour, %{
            "switchbackStartAt" => @anchor + 1,
            "assignmentRules" => @assign_1
          })
        ]),
        %{@unit_type => "15"}
      )

    assert Context.treatment(ctx, "sb_full_on") == 1
    assert Context.treatment(ctx, "sb_rules") == 1
    assert Context.treatment(ctx, "sb_unaligned_rules") == 1

    assert publish_exposures(ctx, events) == [
             exposure(1, "sb_full_on", 1, @anchor, true, true, %{"fullOn" => true}),
             exposure(2, "sb_rules", 1, @anchor, false, true, %{"ruleOverride" => true}),
             exposure(3, "sb_unaligned_rules", 1, @anchor, false, true, %{"ruleOverride" => true})
           ]
  end

  # assignmentRulesDoNotApplyToAnIneligibleCluster
  test "assignment rules do not apply to an ineligible cluster", %{clock: clock} do
    experiment =
      sb(2, @hour, %{
        "assignmentRules" => @assign_1,
        "switchbackClusterValues" => ["other-store"]
      })

    {ctx, _} = create(clock, data(experiment))
    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.pending(ctx) == 0
  end

  # splitRuleRandomizesOverTheServingUnit
  test "a split rule randomizes over the serving unit", %{clock: clock} do
    experiment =
      sb(2, @hour, %{
        "unitType" => "user_id",
        "assignmentRules" =>
          ~s({"rules":[{"type":"split","environments":[],"percentages":"50/50"}]})
      })

    variants =
      for u <- 0..31 do
        uid = "store-#{u}"

        expected =
          ABSmartly.VariantAssigner.assign(
            ABSmartly.Utils.hash_unit(uid),
            [0.5, 0.5],
            @seed_hi,
            @seed_lo
          )

        {ctx, events} =
          create(clock, data(experiment), %{@unit_type => uid, "user_id" => "fixed-user"})

        assert Context.treatment(ctx, "exp_sb") == expected, uid
        assert publish_exposures(ctx, events) == [rule_exposure("exp_sb", expected, @anchor)]
        expected
      end

    assert 0 in variants and 1 in variants
  end

  # audienceStrictMismatchIsRecordedAsControl
  test "a strict audience mismatch is recorded as control", %{clock: clock} do
    strict = %{"audience" => @strict_gold, "audienceStrict" => true}
    {ctx, events} = create(clock, data(sb(2, @hour, strict)))
    set(clock, @anchor + @hour)
    assert Context.treatment(ctx, "exp_sb") == 0
    assert publish_exposures(ctx, events) == [strict_mismatch_exposure(@anchor + @hour)]
  end

  # audienceStrictMismatchExposureSerializesExactly
  test "a strict audience mismatch publishes the exact wire form", %{clock: clock} do
    assert e2(1) == 1
    strict = %{"audience" => @strict_gold, "audienceStrict" => true}
    {ctx, events} = create(clock, data(sb(2, @hour, strict)))
    set(clock, @anchor + @hour + 5)
    Context.treatment(ctx, "exp_sb")
    set(clock, @anchor + @hour + 9)

    assert publish_events(ctx, events) == [
             %{
               "hashed" => true,
               "publishedAt" => @anchor + @hour + 9,
               "units" => [%{"type" => @unit_type, "uid" => @uid_hash}],
               "exposures" => [strict_mismatch_exposure(@anchor + @hour + 5)],
               "goals" => [],
               "attributes" => [
                 %{"name" => @cluster_path, "value" => @cluster_key, "setAt" => @anchor}
               ]
             }
           ]
  end

  # audienceStrictMismatchBeforeTheAnchorIsRecorded
  test "a strict audience mismatch before the anchor is recorded", %{clock: clock} do
    set(clock, @anchor - 1)
    strict = %{"audience" => @strict_gold, "audienceStrict" => true}
    {ctx, events} = create(clock, data(sb(2, @hour, strict)))
    assert Context.treatment(ctx, "exp_sb") == 0
    assert publish_exposures(ctx, events) == [strict_mismatch_exposure(@anchor - 1)]
  end

  # audienceStrictMismatchWithAnUnservableScheduleIsRecorded
  test "a strict audience mismatch with an unservable schedule is recorded", %{clock: clock} do
    set(clock, @anchor + @hour + 3)

    strict = %{"audience" => @strict_gold, "audienceStrict" => true, "switchbackStartAt" => nil}
    {ctx, events} = create(clock, data(sb(2, @hour, strict)))
    assert Context.treatment(ctx, "exp_sb") == 0
    assert publish_exposures(ctx, events) == [strict_mismatch_exposure(@anchor + @hour + 3)]
  end

  # audienceStrictMismatchWithAMissingOrUnreadableClusterMapRecordsNothing
  test "a strict mismatch on the legacy path records nothing", %{clock: clock} do
    for clusters <- [nil, clusters([{@unit_type, "'geo"}])] do
      set(clock, @anchor + @hour + 3)

      experiment =
        sb(2, @hour, %{
          "audience" => @strict_gold,
          "audienceStrict" => true,
          "switchbackClusters" => clusters
        })

      {ctx, _} = create(clock, data(experiment))
      assert Context.treatment(ctx, "exp_sb") == 0, inspect(clusters)
      assert Context.pending(ctx) == 0, inspect(clusters)
    end
  end

  # strictMismatchedSwitchbackGivesWayOnASharedVariableKey
  test "a strict-mismatched switchback gives way on a shared variable key", %{clock: clock} do
    sb = sb(2, @hour, %{"audience" => @strict_gold, "audienceStrict" => true})

    unit =
      switchback(2, "exp_unit", 2, @hour, %{
        "fullOnVariant" => 1,
        "variants" => [
          %{"name" => "A", "config" => ~s({"sb.arm":10})},
          %{"name" => "B", "config" => ~s({"sb.arm":11})}
        ]
      })
      |> as_unit()

    set(clock, @anchor + @hour + 3)
    {ctx, events} = create(clock, data([sb, unit]))
    assert Context.variable_keys(ctx) == %{"sb.arm" => ["exp_sb", "exp_unit"]}

    assert Context.peek_variable_value(ctx, "sb.arm", -1) == 11
    assert Context.pending(ctx) == 0
    assert Context.variable_value(ctx, "sb.arm", -1) == 11

    assert publish_exposures(ctx, events) == [
             exposure(2, "exp_unit", 1, @anchor + @hour + 3, true, true, %{"fullOn" => true})
           ]
  end

  # strictMismatchedSwitchbackAloneOnAVariableKeyReturnsTheDefault
  test "a strict-mismatched switchback alone on a key returns the default", %{clock: clock} do
    sb = sb(2, @hour, %{"audience" => @strict_gold, "audienceStrict" => true})
    set(clock, @anchor + @hour + 3)
    {ctx, _} = create(clock, data(sb))
    assert Context.peek_variable_value(ctx, "sb.arm", -1) == -1
    assert Context.variable_value(ctx, "sb.arm", -1) == -1
    assert Context.pending(ctx) == 0
  end

  # exposureFlagsMatchAUnitExperimentForEveryBranch: the SWITCHBACK.md
  # "Exposure flags" table. Columns: assigned, eligible, overridden, fullOn,
  # custom, audienceMismatch, ruleOverride; then the switchback's variant at
  # period 2 (whose 3-arm draw is 1).
  @parity [
    override: {[false, true, true, false, false, false, false], 2},
    override_over_strict_mismatch: {[false, true, true, false, false, false, false], 2},
    rule: {[false, true, false, false, false, false, true], 2},
    rule_over_strict_mismatch: {[false, true, false, false, false, false, true], 2},
    strict_mismatch: {[false, true, false, false, false, true, false], 0},
    strict_mismatch_over_full_on: {[false, true, false, false, false, true, false], 0},
    strict_mismatch_over_traffic_miss: {[false, true, false, false, false, true, false], 0},
    non_strict_mismatch: {[true, true, false, false, false, true, false], 1},
    full_on: {[true, true, false, true, false, false, false], 2},
    traffic_miss: {[true, false, false, false, false, false, false], 0},
    custom: {[true, true, false, false, true, false, false], 2},
    draw: {[true, true, false, false, false, false, false], 1}
  ]

  defp configure(experiment, branch) do
    strict = %{"audience" => @strict_gold, "audienceStrict" => true}

    extra =
      case branch do
        b
        when b in [:override_over_strict_mismatch, :rule_over_strict_mismatch, :strict_mismatch] ->
          strict

        :strict_mismatch_over_full_on ->
          Map.put(strict, "fullOnVariant", 2)

        :strict_mismatch_over_traffic_miss ->
          Map.put(strict, "trafficSplit", [1.0, 0.0])

        :non_strict_mismatch ->
          %{"audience" => @strict_gold}

        :full_on ->
          %{"fullOnVariant" => 2}

        :traffic_miss ->
          %{"trafficSplit" => [1.0, 0.0]}

        _ ->
          %{}
      end

    extra =
      if branch in [:rule, :rule_over_strict_mismatch],
        do: Map.put(extra, "assignmentRules", @assign_2),
        else: extra

    Map.merge(experiment, extra)
  end

  defp expose_once(clock, experiment, branch) do
    {ctx, events} = create(clock, data(configure(experiment, branch)))

    cond do
      branch in [:override, :override_over_strict_mismatch] ->
        :ok = Context.set_override(ctx, "exp_parity", 2)

      branch == :custom ->
        :ok = Context.set_custom_assignment(ctx, "exp_parity", 2)

      true ->
        :ok
    end

    Context.treatment(ctx, "exp_parity")
    [exposure] = publish_exposures(ctx, events)
    exposure
  end

  @flag_keys ~w(assigned eligible overridden fullOn custom audienceMismatch ruleOverride)

  for {branch, {flags, variant}} <- @parity do
    @branch branch
    @flags flags
    @variant variant
    test "exposure flags match a unit experiment: #{branch}", %{clock: clock} do
      set(clock, @anchor + 2 * @hour + 3)
      assert e3(2) == 1

      unit = expose_once(clock, as_unit(switchback(1, "exp_parity", 3, @hour)), @branch)
      sb = expose_once(clock, switchback(1, "exp_parity", 3, @hour), @branch)

      assert Enum.map(@flag_keys, &unit[&1]) == @flags, "unit #{@branch}"
      assert Enum.map(@flag_keys, &sb[&1]) == @flags, "switchback #{@branch}"
      assert sb["variant"] == @variant

      unless @branch in [:draw, :non_strict_mismatch],
        do: assert(unit["variant"] == @variant)

      assert Map.take(unit, ~w(id name exposedAt unit)) ==
               Map.take(sb, ~w(id name exposedAt unit))
    end
  end

  # trafficMissOnAnEligibleClusterPublishesAnIneligibleExposure
  test "a traffic miss on an eligible cluster publishes an ineligible exposure", %{clock: clock} do
    {ctx, events} =
      create(
        clock,
        data([
          switchback(1, "exp_miss", 2, @hour, %{"trafficSplit" => [1.0, 0.0]}),
          switchback(2, "exp_cluster_ineligible", 2, @hour, %{
            "trafficSplit" => [1.0, 0.0],
            "switchbackClusterValues" => ["other-store"]
          })
        ])
      )

    set(clock, @anchor + 2 * @hour + 3)
    assert Context.treatment(ctx, "exp_miss") == 0
    assert Context.treatment(ctx, "exp_cluster_ineligible") == 0

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_miss", 0, @anchor + 2 * @hour + 3, true, false)
           ]
  end

  # customFieldValuesAndUnitLookupsWork
  test "custom field values and unit lookups work", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))
    assert Context.get_unit(ctx, @unit_type) == @uid
    assert Context.custom_field_keys(ctx) == []
    assert Context.custom_field_value(ctx, "exp_sb", "missing") == nil
  end

  # perPeriodCacheIsBounded
  test "the per-period cache is bounded", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))

    for i <- 0..49 do
      set(clock, @anchor + i * @hour)
      Context.treatment(ctx, "exp_sb")
    end

    slots = :sys.get_state(ctx).switchback_slots["exp_sb"].slots
    assert slots |> Map.keys() |> Enum.sort() == [48, 49]
    assert :sys.get_state(ctx).assignments == %{}
    assert Context.pending(ctx) == 50
  end

  # unitTypeIsNotUsedForSwitchbackAssignment
  test "unitType is not used for switchback assignment", %{clock: clock} do
    {ctx, events} =
      create(clock, data(sb(2, @hour, %{"unitType" => "user_id"})), %{
        @unit_type => @uid,
        "user_id" => "u1"
      })

    for i <- 0..2 do
      set(clock, @anchor + i * @hour)
      assert Context.treatment(ctx, "exp_sb") == e2(i)
    end

    exposures = publish_exposures(ctx, events)
    assert length(exposures) == 3
    assert Enum.all?(exposures, &(&1["unit"] == @unit_type))
  end

  # publishPayloadHasNoNewFields
  test "the publish payload has no new fields", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 5)
    Context.treatment(ctx, "exp_sb")
    set(clock, @anchor + @hour + 7)
    Context.treatment(ctx, "exp_sb")
    set(clock, @anchor + @hour + 9)

    [event] = publish_events(ctx, events)
    refute e2(0) == e2(1)

    assert Jason.encode!(event) ==
             Jason.encode!(%{
               "hashed" => true,
               "publishedAt" => @anchor + @hour + 9,
               "units" => [%{"type" => @unit_type, "uid" => @uid_hash}],
               "exposures" => [
                 exposure(1, "exp_sb", e2(0), @anchor + 5, true, true),
                 exposure(1, "exp_sb", e2(1), @anchor + @hour + 7, true, true)
               ],
               "goals" => [],
               # Published with its timestamp: the Collector re-resolves the
               # cluster at exposedAt from it.
               "attributes" => [
                 %{"name" => @cluster_path, "value" => @cluster_key, "setAt" => @anchor}
               ]
             })
  end

  # periodsPublishedAcrossFlushesStayOnePerPeriod
  test "periods published across flushes stay one per period", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour)))
    Context.treatment(ctx, "exp_sb")
    first = publish_exposures(ctx, events)
    set(clock, @anchor + 1)
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 0
    set(clock, @anchor + @hour)
    Context.treatment(ctx, "exp_sb")
    second = publish_exposures(ctx, events)
    assert Enum.map(first ++ second, & &1["variant"]) == [e2(0), e2(1)]
  end

  # treatmentExposureIsStampedWithTheResolutionInstant
  test "a treatment exposure is stamped with the resolution instant", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + @hour)
    next_read(clock, @anchor + @hour - 1)
    assert Context.treatment(ctx, "exp_sb") == e2(0)

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", e2(0), @anchor + @hour - 1, true, true)
           ]
  end

  # variableExposureIsStampedWithTheResolutionInstant
  test "a variable exposure is stamped with the resolution instant", %{clock: clock} do
    covered = sb(2, @hour, %{"holdoutIds" => [11]})
    {ctx, events} = create(clock, data(covered, [holdout([0.0, 1.0])]))
    set(clock, @anchor + @hour)
    next_read(clock, @anchor + @hour - 1)
    assert Context.variable_value(ctx, "sb.arm", -1) == e2(0)

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", e2(0), @anchor + @hour - 1, true, true)
           ]
  end

  # exposureAfterPeekUsesTheExposingCallsInstant
  test "an exposure after a peek uses the exposing call's instant", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 10)
    assert Context.peek(ctx, "exp_sb") == e2(0)
    set(clock, @anchor + 20 * 60_000)
    assert Context.treatment(ctx, "exp_sb") == e2(0)

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", e2(0), @anchor + 20 * 60_000, true, true)
           ]
  end

  # unitExposureTimingIsUnchanged: a unit experiment reads the clock only
  # when its exposure is enqueued, as before switchbacks (Java reads it once
  # more to resolve, so its one-shot reading is consumed earlier there).
  test "unit exposure timing is unchanged", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour, %{"randomizationType" => "unit"})))
    set(clock, @anchor + @hour)
    next_read(clock, @anchor + @hour - 1)
    variant = Context.treatment(ctx, "exp_sb")
    assert Context.treatment(ctx, "exp_sb") == variant

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", variant, @anchor + @hour - 1, true, true)
           ]
  end

  # gridRefreshToALowerIndexExposesOnce
  test "a grid refresh to a lower index exposes once", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 99 * @hour)
    Context.treatment(ctx, "exp_sb")
    set(clock, @anchor + 100 * @hour)
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 2

    refresh(ctx, [sb(2, @hour, %{"switchbackStartAt" => @anchor + 100 * @hour})])
    for _ <- 1..3, do: assert(Context.treatment(ctx, "exp_sb") == e2(0))
    assert Context.pending(ctx) == 3
  end

  # periodLengthRefreshToALowerIndexExposesOnce
  test "a period-length refresh to a lower index exposes once", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 100 * @hour)
    Context.treatment(ctx, "exp_sb")
    set(clock, @anchor + 101 * @hour)
    Context.treatment(ctx, "exp_sb")

    refresh(ctx, [sb(2, 200 * @hour)])
    Context.treatment(ctx, "exp_sb")
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 3
  end

  # clockRewindReexposesAnEvictedPeriodAtMostOnce
  test "a clock rewind re-exposes an evicted period at most once", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour)))

    for i <- 0..2 do
      set(clock, @anchor + i * @hour)
      Context.treatment(ctx, "exp_sb")
    end

    assert Context.pending(ctx) == 3

    set(clock, @anchor)
    for _ <- 1..3, do: assert(Context.treatment(ctx, "exp_sb") == e2(0))
    assert Context.pending(ctx) == 4

    # Retained {0, 2}: period 2 is still deduplicated, period 1 was evicted.
    set(clock, @anchor + 2 * @hour)
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 4
    set(clock, @anchor + @hour)
    for _ <- 1..3, do: assert(Context.treatment(ctx, "exp_sb") == e2(1))
    assert Context.pending(ctx) == 5

    exposures = publish_exposures(ctx, events)
    assert Enum.at(exposures, 3) == exposure(1, "exp_sb", e2(0), @anchor, true, true)
    assert Enum.at(exposures, 4) == exposure(1, "exp_sb", e2(1), @anchor + @hour, true, true)
  end

  # overrideIsReresolvedWhenTheGridChanges
  test "an override is re-resolved when the grid changes", %{clock: clock} do
    original = sb(3, @hour, %{"holdoutIds" => [11]})
    {ctx, events} = create(clock, data(original, [holdout([0.0, 1.0])]))
    :ok = Context.set_override(ctx, "exp_sb", 2)

    set(clock, @anchor + 10)
    assert Context.treatment(ctx, "exp_sb") == 2
    assert Context.variable_value(ctx, "sb.arm", -1) == 2
    assert Context.pending(ctx) == 1

    regridded = sb(3, 2 * @hour, %{"holdoutIds" => [11]})

    regridded =
      put_in(regridded, ["variants", Access.at(2), "config"], ~s({"sb.arm":22}))

    refresh(ctx, [regridded], [holdout([0.0, 1.0])])
    assert Context.treatment(ctx, "exp_sb") == 2
    assert Context.variable_value(ctx, "sb.arm", -1) == 22
    assert Context.pending(ctx) == 2

    override = exposure(1, "exp_sb", 2, @anchor + 10, false, true, %{"overridden" => true})
    assert publish_exposures(ctx, events) == [override, override]
  end

  # switchbackToUnitToIdenticalSwitchbackReresolves
  test "switchback to unit to an identical switchback re-resolves", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 10)
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 1

    refresh(ctx, [sb(2, @hour, %{"randomizationType" => "unit"})])
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 2

    refresh(ctx, [sb(2, @hour)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 3
  end

  # removedAndRestoredSwitchbackReresolves
  test "a removed and restored switchback re-resolves", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 10)
    Context.treatment(ctx, "exp_sb")

    refresh(ctx, [])
    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.pending(ctx) == 2

    refresh(ctx, [sb(2, @hour)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 3
  end

  # preAnchorSlotIsDroppedWhenTheGridChanges
  test "the pre-anchor slot is dropped when the grid changes", %{clock: clock} do
    grid_a = sb(2, @hour, %{"switchbackStartAt" => @anchor + 10 * @hour})
    {ctx, _} = create(clock, data(grid_a))
    set(clock, @anchor + 10)
    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.pending(ctx) == 0

    refresh(ctx, [sb(2, @hour)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 1

    refresh(ctx, [grid_a])
    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.pending(ctx) == 1
    assert Context.variable_value(ctx, "sb.arm", -1) == 0
    assert Context.pending(ctx) == 1
  end

  # transitionsWithoutAnInterveningLookupStillReresolve
  test "transitions without an intervening lookup still re-resolve", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 10)
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 1

    refresh(ctx, [sb(2, @hour, %{"randomizationType" => "unit"})])
    refresh(ctx, [sb(2, @hour)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 2

    refresh(ctx, [])
    refresh(ctx, [sb(2, @hour)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 3

    refresh(ctx, [sb(2, @hour, %{"switchbackDesignType" => "other"})])
    refresh(ctx, [sb(2, @hour)])
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert Context.pending(ctx) == 4

    # An unchanged identity keeps the epoch.
    refresh(ctx, [sb(2, @hour)])
    Context.treatment(ctx, "exp_sb")
    assert Context.pending(ctx) == 4
  end

  # legacySwitchbackUnitTypeChangeIsIdentity
  test "on the legacy path a unitType change is identity", %{clock: clock} do
    legacy = sb(2, @hour, %{"switchbackClusters" => nil})
    {ctx, _} = create(clock, data(legacy), %{@unit_type => @uid, "user_id" => "u1"})
    set(clock, @anchor + 10)
    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.variable_value(ctx, "sb.arm", -1) == 0
    assert slot_unit(ctx) == @unit_type

    refresh(ctx, [Map.put(legacy, "unitType", "other")])
    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.variable_value(ctx, "sb.arm", -1) == -1

    refresh(ctx, [Map.put(legacy, "unitType", "user_id")])
    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.variable_value(ctx, "sb.arm", -1) == 0
    assert slot_unit(ctx) == "user_id"
    assert Context.pending(ctx) == 0
  end

  defp slot_unit(ctx) do
    %{slots: slots} = :sys.get_state(ctx).switchback_slots["exp_sb"]
    [slot] = Map.values(slots)
    refute slot.assignment.eligible
    assert slot.silent
    slot.unit_type
  end

  # rulesAreNotReevaluatedForAnIneligibleOrAbsentSlot
  test "rules are not re-evaluated for an ineligible or absent slot", %{clock: clock} do
    ineligible =
      switchback(1, "exp_ineligible", 2, @hour, %{
        "assignmentRules" => @assign_1,
        "switchbackClusterValues" => ["other-store"]
      })

    absent =
      switchback(2, "exp_absent", 2, @hour, %{
        "assignmentRules" => @assign_1,
        "switchbackClusters" => clusters([{"device_id", @cluster_path}])
      })

    {ctx, _} = create(clock, data([ineligible, absent]))
    set(clock, @anchor + 10)

    calls =
      count_rule_evaluations(ctx, fn ->
        assert Context.treatment(ctx, "exp_ineligible") == 0
        assert Context.treatment(ctx, "exp_absent") == 0
        :ok = Context.set_attribute(ctx, "x", 1)

        changed = ~s({"rules":[{"type":"assign","environments":[],"variant":1,"name":"changed"}]})

        refresh(ctx, [
          Map.put(ineligible, "assignmentRules", changed),
          Map.put(absent, "assignmentRules", changed)
        ])

        assert Context.treatment(ctx, "exp_ineligible") == 0
        assert Context.treatment(ctx, "exp_absent") == 0
      end)

    assert calls == 0
    assert Context.pending(ctx) == 0
  end

  defp count_rule_evaluations(ctx, fun) do
    :erlang.trace(ctx, true, [:call, {:tracer, self()}])
    :erlang.trace_pattern({ABSmartly.Matcher, :evaluate_rules, 3}, true, [:local])

    try do
      fun.()
    after
      :erlang.trace(ctx, false, [:call])
    end

    count_traces(0)
  end

  defp count_traces(n) do
    receive do
      {:trace, _, :call, {ABSmartly.Matcher, :evaluate_rules, _}} -> count_traces(n + 1)
    after
      50 -> n
    end
  end

  # inPeriodRuleRefreshKeepsTheVariantAndExposesOnce
  test "an in-period rule refresh keeps the variant and exposes once", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour, %{"assignmentRules" => @assign_1})))
    set(clock, @anchor + 5)
    assert Context.treatment(ctx, "exp_sb") == 1

    :ok = Context.set_attribute(ctx, "tier", "x")

    rules =
      ~s({"rules":[{"type":"assign","environments":[],"variant":1,"conditions":{"and":[{"eq":[{"var":"tier"},{"value":"x"}]}]}}]})

    refresh(ctx, [sb(2, @hour, %{"assignmentRules" => rules})])
    set(clock, @anchor + 6)
    assert Context.treatment(ctx, "exp_sb") == 1
    assert publish_exposures(ctx, events) == [rule_exposure("exp_sb", 1, @anchor + 5)]
  end

  # preAnchorTrafficMissIsSilent
  test "a pre-anchor traffic miss is silent", %{clock: clock} do
    set(clock, @anchor - 1)
    {ctx, events} = create(clock, data(sb(2, @hour, %{"trafficSplit" => [1.0, 0.0]})))
    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.pending(ctx) == 0

    set(clock, @anchor)
    assert Context.treatment(ctx, "exp_sb") == 0
    assert publish_exposures(ctx, events) == [exposure(1, "exp_sb", 0, @anchor, true, false)]
  end

  # overrideWithoutAServingUnitOnALegacySwitchbackUsesTheDeclaredUnitType
  test "an override on a legacy switchback is recorded under the declared unitType", %{
    clock: clock
  } do
    {ctx, events} =
      create(
        clock,
        data([
          switchback(1, "exp_missing_map", 2, @hour, %{
            "unitType" => "user_id",
            "switchbackClusters" => nil
          }),
          switchback(2, "exp_unreadable_map", 2, @hour, %{
            "unitType" => "user_id",
            "switchbackClusters" => clusters([{@unit_type, "'unterminated"}])
          })
        ])
      )

    :ok = Context.set_override(ctx, "exp_missing_map", 1)
    :ok = Context.set_override(ctx, "exp_unreadable_map", 1)
    set(clock, @anchor + 5)
    assert Context.treatment(ctx, "exp_missing_map") == 1
    assert Context.treatment(ctx, "exp_unreadable_map") == 1

    overridden = %{"overridden" => true, "unit" => "user_id"}

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_missing_map", 1, @anchor + 5, false, true, overridden),
             exposure(2, "exp_unreadable_map", 1, @anchor + 5, false, true, overridden)
           ]
  end

  # ruleWonAndTrafficMissExposuresSerializeExactly
  test "rule-won and traffic-miss exposures serialize exactly", %{clock: clock} do
    {ctx, events} =
      create(
        clock,
        data([
          switchback(1, "exp_rule", 2, @hour, %{"assignmentRules" => @assign_1}),
          switchback(2, "exp_miss", 2, @hour, %{"trafficSplit" => [1.0, 0.0]})
        ])
      )

    set(clock, @anchor + 5)
    Context.treatment(ctx, "exp_rule")
    Context.treatment(ctx, "exp_miss")

    assert publish_exposures(ctx, events) == [
             rule_exposure("exp_rule", 1, @anchor + 5),
             exposure(2, "exp_miss", 0, @anchor + 5, true, false)
           ]
  end

  # concurrentResolutionOfTheSamePeriodExposesOnce: a context serializes its
  # calls, so many callers in one period expose once.
  test "concurrent resolution of the same period exposes once", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + @hour)

    1..16
    |> Enum.map(fn _ -> Task.async(fn -> Context.treatment(ctx, "exp_sb") end) end)
    |> Enum.map(&Task.await/1)
    |> Enum.each(&assert(&1 == e2(1)))

    assert Context.pending(ctx) == 1
  end
end
