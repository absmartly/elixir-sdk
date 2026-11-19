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

  test "burn-in, burn-out and carryover never change serving or exposures", %{clock: clock} do
    windows = %{
      "switchbackBurnInDurationMs" => 900_000,
      "switchbackBurnOutDurationMs" => 900_000,
      "switchbackCarryoverDurationMs" => 1_800_000
    }

    {ctx, events} = create(clock, data(sb(3, @hour, windows)))

    for {i, offset} <- [{0, 0}, {1, 1}, {2, @hour - 1}, {3, 450_000}] do
      set(clock, @anchor + i * @hour + offset)
      assert Context.treatment(ctx, "exp_sb") == e3(i)
    end

    assert publish_exposures(ctx, events) ==
             for(
               {i, offset} <- [{0, 0}, {1, 1}, {2, @hour - 1}, {3, 450_000}],
               do: exposure(1, "exp_sb", e3(i), @anchor + i * @hour + offset, true, true)
             )
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
    # The unit experiment randomizes over the unit where the switchback draws.
    @unit_variant_fixed branch not in [:draw, :non_strict_mismatch]
    test "exposure flags match a unit experiment: #{branch}", %{clock: clock} do
      set(clock, @anchor + 2 * @hour + 3)
      assert e3(2) == 1

      unit = expose_once(clock, as_unit(switchback(1, "exp_parity", 3, @hour)), @branch)
      sb = expose_once(clock, switchback(1, "exp_parity", 3, @hour), @branch)

      assert Enum.map(@flag_keys, &unit[&1]) == @flags, "unit #{@branch}"
      assert Enum.map(@flag_keys, &sb[&1]) == @flags, "switchback #{@branch}"
      assert sb["variant"] == @variant

      if @unit_variant_fixed, do: assert(unit["variant"] == @variant)

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

  # Seed and split are not switchback identity: a same-period refresh that
  # edits them keeps the slot and exposes nothing more.
  test "a seed or split refresh neither re-resolves nor re-exposes the period", %{clock: clock} do
    for change <- [%{"seedHi" => 99}, %{"seedLo" => 99}, %{"split" => [0.9, 0.1]}] do
      set(clock, @anchor + 5)
      {ctx, events} = create(clock, data(sb(2, @hour)))
      assert Context.treatment(ctx, "exp_sb") == e2(0)
      refresh(ctx, [sb(2, @hour, change)])
      assert Context.treatment(ctx, "exp_sb") == e2(0), inspect(change)

      assert publish_exposures(ctx, events) == [
               exposure(1, "exp_sb", e2(0), @anchor + 5, true, true)
             ]
    end
  end

  test "a custom assignment set mid-period applies within the period", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour)))
    set(clock, @anchor + 5)
    v = Context.peek(ctx, "exp_sb")
    :ok = Context.set_custom_assignment(ctx, "exp_sb", 1 - v)
    assert Context.peek(ctx, "exp_sb") == 1 - v
    assert Context.treatment(ctx, "exp_sb") == 1 - v

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", 1 - v, @anchor + 5, true, true, %{"custom" => true})
           ]
  end

  # An exposed override recorded before any linked unit was set has already
  # published, so setting the unit keeps it rather than exposing it again.
  test "an exposed override without a linked unit is not re-exposed after set_unit", %{
    clock: clock
  } do
    {ctx, events} = create(clock, data(sb(2, @hour)), %{"user_id" => "u1"})
    :ok = Context.set_override(ctx, "exp_sb", 1)
    set(clock, @anchor + 5)
    assert Context.treatment(ctx, "exp_sb") == 1
    :ok = Context.set_unit(ctx, @unit_type, @uid)
    assert Context.treatment(ctx, "exp_sb") == 1

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", 1, @anchor + 5, false, true, %{"overridden" => true})
           ]
  end

  # A plain map of two or more entries has no declared order, so the
  # experiment is not served rather than served by a guessed unit.
  test "an unordered multi-entry cluster map is not served", %{clock: clock} do
    plain = %{@unit_type => @cluster_path, "user_id" => @cluster_path}

    data =
      ABSmartly.Types.ContextData.from_map(%{
        "experiments" => [sb(2, @hour, %{"switchbackClusters" => plain})]
      })

    assert hd(data.experiments).switchback_clusters == nil

    {:ok, events} = Agent.start_link(fn -> [] end)

    {:ok, ctx} =
      Context.start_link(
        %ABSmartly.Types.SDKConfig{
          endpoint: "e",
          api_key: "k",
          application: "website",
          environment: "production",
          publisher: ABSmartly.Test.OkPublisher
        },
        data,
        %ABSmartly.Types.ContextConfig{
          units: %{@unit_type => @uid, "user_id" => "u1"},
          attributes: %{@cluster_path => @cluster_key},
          event_handler: fn type, payload -> Agent.update(events, &[{type, payload} | &1]) end
        },
        clock: fn -> read(clock) end
      )

    assert Context.treatment(ctx, "exp_sb") == 0
    assert Context.pending(ctx) == 0
  end

  test "integer and boolean allow-list entries match their text", %{clock: clock} do
    for {value, allowed} <- [{42, [42]}, {"true", [true]}] do
      {ctx, events} =
        start(
          clock,
          %{@unit_type => @uid},
          data(sb(2, @hour, %{"switchbackClusterValues" => allowed})),
          attributes: %{@cluster_path => value}
        )

      Context.treatment(ctx, "exp_sb")
      assert [%{"eligible" => true}] = publish_exposures(ctx, events), inspect(allowed)
    end
  end

  # A long-lived context that refreshes through many switchback names keeps
  # slots only for the switchbacks it currently has.
  test "a refresh releases the slots of experiments that are no longer switchbacks", %{
    clock: clock
  } do
    {ctx, _} = create(clock, data([]))

    for i <- 1..50 do
      refresh(ctx, [switchback(i, "sb_#{i}", 2, @hour)])
      Context.treatment(ctx, "sb_#{i}")
    end

    assert Map.keys(:sys.get_state(ctx).switchback_slots) == ["sb_50"]

    refresh(ctx, [switchback(1, "sb_50", 2, @hour, %{"randomizationType" => "unit"})])
    assert :sys.get_state(ctx).switchback_slots == %{}
    refresh(ctx, [])
    assert :sys.get_state(ctx).switchback_slots == %{}
  end

  # Rule environments are matched against the configured environment
  # ("production" here), never a user attribute named "environment".
  test "a switchback rule's environment scope ignores the user environment attribute", %{
    clock: clock
  } do
    staging = ~s({"rules":[{"type":"assign","environments":["staging"],"variant":2}]})
    {ctx, events} = create(clock, data(sb(3, @hour, %{"assignmentRules" => staging})))
    :ok = Context.set_attribute(ctx, "environment", "staging")
    set(clock, @anchor + 5)
    assert Context.treatment(ctx, "exp_sb") == e3(0)

    assert [%{"ruleOverride" => false, "variant" => v}] = publish_exposures(ctx, events)
    assert v == e3(0)
  end

  # A refresh that edits the rules without changing their outcome is
  # validated once; later reads in the period evaluate nothing.
  test "a same-outcome rule refresh is validated once, then the stamp holds", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour, %{"assignmentRules" => @assign_1})))
    set(clock, @anchor + 5)
    assert Context.treatment(ctx, "exp_sb") == 1

    respaced = ~s({"rules": [{"type": "assign", "environments": [], "variant": 1}]})
    refresh(ctx, [sb(2, @hour, %{"assignmentRules" => respaced})])

    # The first read after the refresh validates the new rules once; the
    # next 19 reuse the stamp.
    first = count_rule_evaluations(ctx, fn -> assert Context.treatment(ctx, "exp_sb") == 1 end)
    assert first == 1

    rest =
      count_rule_evaluations(ctx, fn ->
        for _ <- 1..19, do: assert(Context.treatment(ctx, "exp_sb") == 1)
      end)

    assert rest == 0
  end

  # A refresh to a rule with another variant is seen by the first read in
  # the same period: skipping the validation would keep serving variant 1.
  test "a rule refresh to another variant re-resolves the period's slot", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(3, @hour, %{"assignmentRules" => @assign_1})))
    set(clock, @anchor + 5)
    assert Context.treatment(ctx, "exp_sb") == 1

    refresh(ctx, [sb(3, @hour, %{"assignmentRules" => @assign_2})])
    set(clock, @anchor + 6)
    assert Context.treatment(ctx, "exp_sb") == 2

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", 1, @anchor + 5, false, true, %{"ruleOverride" => true}),
             exposure(1, "exp_sb", 2, @anchor + 6, false, true, %{"ruleOverride" => true})
           ]
  end

  # As in the Java SDK, a pre-anchor resolution has its own slot and never
  # evicts a retained period, so returning to that period exposes nothing new.
  test "a pre-anchor lookup does not evict a retained period", %{clock: clock} do
    {ctx, events} = create(clock, data(sb(2, @hour)))

    for i <- 0..1 do
      set(clock, @anchor + i * @hour)
      Context.treatment(ctx, "exp_sb")
    end

    set(clock, @anchor - 1)
    assert Context.treatment(ctx, "exp_sb") == 0
    set(clock, @anchor)
    assert Context.treatment(ctx, "exp_sb") == e2(0)

    assert publish_exposures(ctx, events) == [
             exposure(1, "exp_sb", e2(0), @anchor, true, true),
             exposure(1, "exp_sb", e2(1), @anchor + @hour, true, true)
           ]
  end

  defp variable_switchback(id, name, configs, overrides) do
    switchback(id, name, length(configs), @hour, overrides)
    |> Map.put(
      "variants",
      for({config, i} <- Enum.with_index(configs), do: %{"name" => "#{i}", "config" => config})
    )
  end

  # As in the Java SDK, the first assigned experiment in id order wins the
  # key even when its arm does not set it: the caller gets the default, and
  # only the winner is exposed.
  test "a switchback winner whose arm lacks the key gives the default and is the only exposure",
       %{clock: clock} do
    first =
      variable_switchback(1, "sb_first", [~s({"price":"control"}), ~s({"other":1})], %{
        "fullOnVariant" => 1
      })

    second =
      variable_switchback(2, "sb_second", [~s({"price":"later"}), ~s({"price":"later"})], %{})

    set(clock, @anchor + 5)
    {ctx, events} = create(clock, data([first, second]))
    assert Context.peek_variable_value(ctx, "price", "dflt") == "dflt"
    assert Context.pending(ctx) == 0
    assert Context.variable_value(ctx, "price", "dflt") == "dflt"

    assert [%{"name" => "sb_first", "variant" => 1, "fullOn" => true}] =
             publish_exposures(ctx, events)
  end

  @gold ~s({"filter":[{"eq":[{"var":"tier"},{"value":"gold"}]}]})

  defp unit_variable(id, name, configs, overrides) do
    variable_switchback(id, name, configs, overrides)
    |> Map.drop([
      "randomizationType",
      "switchbackClusters",
      "switchbackStartAt",
      "switchbackPeriodMs"
    ])
  end

  # Java (compiled java-sdk 07807b5): a lower-id candidate that does not win
  # the key still fires its holdout, before the winner's own exposure.
  test "a losing candidate on a switchback key fires its holdout before the winner", %{
    clock: clock
  } do
    loses =
      unit_variable(1, "unit_loses", [~s({"price":"u0"}), ~s({"price":"u1"})], %{
        "holdoutIds" => [11],
        "audience" => @gold,
        "audienceStrict" => true
      })

    wins = variable_switchback(2, "sb_wins", [~s({"price":"s0"}), ~s({"price":"s1"})], %{})

    set(clock, @anchor + 5)
    {ctx, events} = create(clock, data([loses, wins], [holdout([0.0, 1.0])]))
    assert Context.peek_variable_value(ctx, "price", "dflt") == "s0"
    assert Context.pending(ctx) == 0
    assert Context.variable_value(ctx, "price", "dflt") == "s0"
    assert Context.variable_value(ctx, "price", "dflt") == "s0"

    assert Enum.map(publish_exposures(ctx, events), &{&1["name"], &1["variant"]}) == [
             {"holdout_a", 1},
             {"sb_wins", 0}
           ]
  end

  # Java: when nothing wins a switchback key, a held-out experiment supplies
  # its control value, and only its holdout is exposed.
  test "a held-out experiment is the fallback on a switchback key nothing wins", %{
    clock: clock
  } do
    held =
      unit_variable(1, "unit_held", [~s({"price":"a0"}), ~s({"price":"a1"})], %{
        "holdoutIds" => [11]
      })

    strict =
      variable_switchback(2, "sb_strict", [~s({"price":"b0"}), ~s({"price":"b1"})], %{
        "audience" => @gold,
        "audienceStrict" => true
      })

    set(clock, @anchor + 5)
    {ctx, events} = create(clock, data([held, strict], [holdout([1.0, 0.0])]))
    assert Context.peek_variable_value(ctx, "price", "dflt") == "a0"
    assert Context.variable_value(ctx, "price", "dflt") == "a0"
    assert Context.variable_value(ctx, "price", "dflt") == "a0"

    assert Enum.map(publish_exposures(ctx, events), &{&1["name"], &1["variant"]}) == [
             {"holdout_a", 0}
           ]
  end

  # Only keys a switchback sets take the Java rule. A unit-only key in a
  # payload that also has a switchback keeps the existing resolution: an
  # assigned experiment whose arm lacks the key passes to the next one.
  test "a key no switchback sets keeps its resolution next to a switchback", %{clock: clock} do
    # uid u3 draws arm 0 in both unit experiments (seeds -5/-7, split 50/50).
    u_a = unit_variable(1, "u_a", [~s({"other":1}), ~s({"color":"a1"})], %{})
    u_b = unit_variable(2, "u_b", [~s({"color":"b0"}), ~s({"color":"b1"})], %{})
    sb = variable_switchback(3, "sb", [~s({"size":1}), ~s({"size":2})], %{})

    set(clock, @anchor + 5)
    {ctx, events} = create(clock, data([u_a, u_b, sb]), %{@unit_type => "u3"})
    assert Map.keys(:sys.get_state(ctx).switchback_variable_index) == ["size"]
    assert Context.variable_value(ctx, "color", "dflt") == "b0"
    assert Enum.map(publish_exposures(ctx, events), & &1["name"]) == ["u_a", "u_b"]
  end

  # The winner on a shared key is the lowest experiment id, whatever the
  # payload order.
  test "shared switchback keys are won by the lowest id in either payload order", %{
    clock: clock
  } do
    one = variable_switchback(1, "sb_one", [~s({"price":"one"}), ~s({"price":"one"})], %{})
    two = variable_switchback(2, "sb_two", [~s({"price":"two"}), ~s({"price":"two"})], %{})

    for experiments <- [[one, two], [two, one]] do
      set(clock, @anchor + 5)
      {ctx, events} = create(clock, data(experiments))
      assert Context.peek_variable_value(ctx, "price", "dflt") == "one"
      assert Context.variable_value(ctx, "price", "dflt") == "one"
      assert [%{"name" => "sb_one"}] = publish_exposures(ctx, events)
    end
  end

  test "set_data and a failed load release slots of experiments that are no longer switchbacks",
       %{
         clock: clock
       } do
    {ctx, _} = create(clock, data([]))

    for i <- 1..10 do
      :ok = Context.set_data(ctx, %{"experiments" => [switchback(i, "sb_#{i}", 2, @hour)]})
      Context.treatment(ctx, "sb_#{i}")
    end

    assert Map.keys(:sys.get_state(ctx).switchback_slots) == ["sb_10"]
    assert Map.keys(:sys.get_state(ctx).switchback_variable_index) == ["sb.arm"]
    :ok = Context.set_failed(ctx, "boom")
    assert :sys.get_state(ctx).switchback_slots == %{}
    assert :sys.get_state(ctx).switchback_variable_index == %{}
    assert Context.variable_value(ctx, "sb.arm", -1) == -1
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

  # An ineligible or absent slot never evaluated its audience either, so a
  # set_attribute does not make the next read evaluate it.
  test "audiences are not re-evaluated for an ineligible or absent slot", %{clock: clock} do
    gold = ~s({"filter":[{"eq":[{"var":"tier"},{"value":"gold"}]}]})

    ineligible =
      switchback(1, "exp_ineligible", 2, @hour, %{
        "audience" => gold,
        "switchbackClusterValues" => ["other-store"]
      })

    absent =
      switchback(2, "exp_absent", 2, @hour, %{
        "audience" => gold,
        "switchbackClusters" => clusters([{"device_id", @cluster_path}])
      })

    {ctx, _} = create(clock, data([ineligible, absent]))
    set(clock, @anchor + 10)
    Context.treatment(ctx, "exp_ineligible")
    Context.treatment(ctx, "exp_absent")

    :erlang.trace(ctx, true, [:call, {:tracer, self()}])
    :erlang.trace_pattern({ABSmartly.Matcher, :evaluate, 2}, true, [:local])

    try do
      for i <- 1..5 do
        :ok = Context.set_attribute(ctx, "tier", "t#{i}")
        assert Context.peek(ctx, "exp_ineligible") == 0
        assert Context.peek(ctx, "exp_absent") == 0
      end
    after
      :erlang.trace(ctx, false, [:call])
    end

    refute_receive {:trace, _, :call, {ABSmartly.Matcher, :evaluate, _}}, 50
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

  @assign_1_to_us ~s({"rules":[{"type":"assign","environments":[],"conditions":{"and":[{"eq":[{"var":"country"},{"value":"US"}]}]},"variant":1}]})

  # staleRuleTransitionEvaluatesTheRulesTwice, plus the same on a switchback:
  # a changed rule outcome evaluates the rules for the stale slot and its
  # rebuild, and once validated the next reads evaluate nothing.
  test "a stale rule transition evaluates the rules, then the stamps hold", %{clock: clock} do
    for type <- ["unit", "switchback"] do
      experiment =
        sb(2, @hour, %{"randomizationType" => type, "assignmentRules" => @assign_1_to_us})

      {ctx, _} = create(clock, data(experiment))
      assert count_rule_evaluations(ctx, fn -> Context.peek(ctx, "exp_sb") end) == 1

      :ok = Context.set_attribute(ctx, "country", "US")
      calls = count_rule_evaluations(ctx, fn -> assert Context.peek(ctx, "exp_sb") == 1 end)
      assert calls in 1..2, type

      # Current again, also after an unrelated attribute and a same-outcome
      # validation: at most one evaluation, then none.
      assert count_rule_evaluations(ctx, fn -> Context.peek(ctx, "exp_sb") end) == 0, type
      :ok = Context.set_attribute(ctx, "x", 1)
      assert count_rule_evaluations(ctx, fn -> Context.peek(ctx, "exp_sb") end) == 1, type

      assert count_rule_evaluations(ctx, fn ->
               for _ <- 1..5, do: Context.peek(ctx, "exp_sb")
             end) == 0,
             type
    end
  end

  test "a warmed switchback read leaves the context state unchanged", %{clock: clock} do
    {ctx, _} = create(clock, data(sb(2, @hour, %{"assignmentRules" => @assign_1_to_us})))
    Context.treatment(ctx, "exp_sb")
    before = :sys.get_state(ctx)
    assert Context.peek(ctx, "exp_sb") == e2(0)
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    assert :sys.get_state(ctx) == before

    # No write-back either: a cache hit puts no slot.
    :erlang.trace(ctx, true, [:call, {:tracer, self()}])
    :erlang.trace_pattern({Context, :put_switchback_epoch, 3}, true, [:local])

    try do
      for _ <- 1..3, do: Context.peek(ctx, "exp_sb")
    after
      :erlang.trace(ctx, false, [:call])
    end

    refute_receive {:trace, _, :call, {Context, :put_switchback_epoch, _}}, 50
  end

  # As in the Java SDK, a refresh that changes trafficSplit or fullOnVariant
  # re-resolves a rule-won slot, and the rebuilt slot is exposed again.
  test "a traffic or full-on refresh re-exposes a rule-won switchback", %{clock: clock} do
    for change <- [%{"trafficSplit" => [0.5, 0.5]}, %{"fullOnVariant" => 1}] do
      set(clock, @anchor)
      {ctx, events} = create(clock, data(sb(2, @hour, %{"assignmentRules" => @assign_1})))
      set(clock, @anchor + 5)
      assert Context.treatment(ctx, "exp_sb") == 1
      refresh(ctx, [sb(2, @hour, Map.put(change, "assignmentRules", @assign_1))])
      set(clock, @anchor + 6)
      assert Context.treatment(ctx, "exp_sb") == 1

      assert publish_exposures(ctx, events) == [
               rule_exposure("exp_sb", 1, @anchor + 5),
               rule_exposure("exp_sb", 1, @anchor + 6)
             ],
             inspect(change)
    end
  end

  test "a switchback without unitType is served, and other experiments keep working", %{
    clock: clock
  } do
    payload =
      data([
        Map.delete(sb(2, @hour), "unitType"),
        switchback(2, "exp_unit", 2, @hour, %{"randomizationType" => nil})
      ])

    {ctx, events} = create(clock, payload)
    assert Context.treatment(ctx, "exp_sb") == e2(0)
    unit = Context.treatment(ctx, "exp_unit")

    [sb_exposure, unit_exposure] = publish_exposures(ctx, events)
    assert sb_exposure == exposure(1, "exp_sb", e2(0), @anchor, true, true)
    assert {unit_exposure["name"], unit_exposure["variant"]} == {"exp_unit", unit}
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
