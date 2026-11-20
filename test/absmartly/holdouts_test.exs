defmodule ABSmartly.HoldoutsTest do
  @moduledoc """
  Holdouts: a holdout arrives in `ContextData.holdouts`, and an experiment is
  covered by the holdouts listed in its `holdoutIds`. Arm 0 of a holdout holds
  the unit out (variant 0, assigned false, no exposure of its own) of every
  experiment it covers; arm 1 of a three-arm holdout holds it out of the
  covered experiments that are not full-on. Each covering holdout publishes
  one ordinary exposure per unit type and iteration.

  A port of the Java SDK's `ContextHoldoutTest` (java-sdk main), which mirrors
  the JavaScript SDK (javascript-sdk#65), the reference. Each test names the
  Java test it ports. The Java tests that reach into JVM internals (the
  exposure settlement loop, the flush scheduler, a refresh running inside the
  event logger) are ported as the behaviour they protect: a context is a
  GenServer, so every call runs to completion before the next one starts.
  """

  use ExUnit.Case, async: true

  alias ABSmartly.{Context, Types}

  @unit_type "session_id"
  @uid "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
  @uid_not_held_out "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"

  # split [0.5, 0.5], seeds 100/200: variant 1 for @uid, 0 for @uid_not_held_out.
  @normal_variant 1

  # split [0.1, 0.9], seeds 13/111: arm 0 (held out) for @uid, arm 1 for
  # @uid_not_held_out.
  @holdout_a {13, 111}
  # split [0.1, 0.9], seeds 1/222: arm 1 (not held out) for both units.
  @holdout_b {1, 222}

  # Three-arm split: seedLo 1 -> arm 0, 3 -> arm 1, 0 -> arm 2 for @uid.
  @three_arm_split [0.3, 0.3, 0.4]
  @three_arm_0 {0, 1}
  @three_arm_1 {0, 3}
  @three_arm_2 {0, 0}

  @us_rule ~s({"rules":[{"name":"US Internal Users","type":"assign","conditions":{"and":[{"eq":[{"var":"country"},{"value":"US"}]}]},"environments":[],"variant":1}]})

  defmodule CapturePublisher do
    @moduledoc false
    @behaviour ABSmartly.ContextPublisher

    def start do
      name = :"holdout_capture_publisher_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Agent.start_link(fn -> [] end, name: name)
      Atom.to_string(name)
    end

    def events(endpoint), do: endpoint |> String.to_existing_atom() |> Agent.get(&Enum.reverse/1)

    @impl ABSmartly.ContextPublisher
    def publish(endpoint, _api_key, _application, _environment, event_map, _retries) do
      Agent.update(String.to_existing_atom(endpoint), &[event_map | &1])
      :ok
    end
  end

  # --- fixtures ---------------------------------------------------------------

  defp experiment(id, name, opts \\ []) do
    %{
      "id" => id,
      "name" => name,
      "iteration" => 1,
      "unitType" => Keyword.get(opts, :unit_type, @unit_type),
      "seedHi" => 100,
      "seedLo" => 200,
      "split" => Keyword.get(opts, :split, [0.5, 0.5]),
      "trafficSeedHi" => 1,
      "trafficSeedLo" => 2,
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => Keyword.get(opts, :full_on, 0),
      "applications" => [%{"name" => "website"}],
      "variants" => Keyword.get(opts, :variants, variants(["A", "B"])),
      "audienceStrict" => Keyword.get(opts, :audience_strict, false),
      "audience" => Keyword.get(opts, :audience),
      "assignmentRules" => Keyword.get(opts, :rules),
      "holdoutIds" => Keyword.get(opts, :holdout_ids)
    }
  end

  defp covered(id, name, holdout_ids, opts \\ []),
    do: experiment(id, name, Keyword.put(opts, :holdout_ids, holdout_ids))

  defp variants(names), do: Enum.map(names, &%{"name" => &1, "config" => nil})

  defp with_config(experiment, variant, config) do
    update_in(experiment, ["variants", Access.at(variant)], &Map.put(&1, "config", config))
  end

  defp with_variables(experiment, key) do
    experiment
    |> with_config(0, Jason.encode!(%{key => "control"}))
    |> with_config(1, Jason.encode!(%{key => "treatment"}))
  end

  # The legacy full experiment shape: unknown fields to the SDK.
  defp holdout(id, name, {seed_hi, seed_lo}, opts \\ []) do
    %{
      "id" => id,
      "name" => name,
      "iteration" => Keyword.get(opts, :iteration, 1),
      "unitType" => Keyword.get(opts, :unit_type, @unit_type),
      "seedHi" => seed_hi,
      "seedLo" => seed_lo,
      "split" => Keyword.get(opts, :split, [0.1, 0.9]),
      "trafficSplit" => [0.0, 1.0],
      "fullOnVariant" => 0,
      "applications" => [],
      "variants" => variants(["A", "B"]),
      "audienceStrict" => false,
      "audience" => nil,
      "holdoutType" => Keyword.get(opts, :holdout_type, "full")
    }
  end

  defp three_arm(id, name, seeds, opts \\ []) do
    holdout(id, name, seeds, [split: @three_arm_split, holdout_type: "all_full_on"] ++ opts)
    |> Map.put("variants", variants(["A", "B", "C"]))
  end

  defp data(holdouts, experiments),
    do: %{"holdouts" => holdouts, "experiments" => List.wrap(experiments)}

  defp start(data, opts \\ []) do
    endpoint = CapturePublisher.start()

    sdk_config = %Types.SDKConfig{
      endpoint: endpoint,
      api_key: "test-api-key",
      application: "website",
      environment: "production",
      publisher: CapturePublisher
    }

    context_config = %Types.ContextConfig{
      units: Keyword.get(opts, :units, %{@unit_type => Keyword.get(opts, :uid, @uid)}),
      overrides: Keyword.get(opts, :overrides, %{}),
      custom_assignments: Keyword.get(opts, :custom_assignments, %{}),
      event_handler: Keyword.get(opts, :event_handler)
    }

    {:ok, ctx} =
      Context.start_link(sdk_config, Types.ContextData.from_map(data), context_config)

    {ctx, endpoint}
  end

  defp exposure(id, name, variant, opts \\ []) do
    %{
      "id" => id,
      "name" => name,
      "unit" => Keyword.get(opts, :unit, @unit_type),
      "variant" => variant,
      "assigned" => Keyword.get(opts, :assigned, true),
      "eligible" => true,
      "overridden" => Keyword.get(opts, :overridden, false),
      "fullOn" => Keyword.get(opts, :full_on, false),
      "custom" => Keyword.get(opts, :custom, false),
      "audienceMismatch" => Keyword.get(opts, :audience_mismatch, false),
      "ruleOverride" => Keyword.get(opts, :rule_override, false)
    }
  end

  defp holdout_exposure(id, name, variant, unit \\ @unit_type),
    do: exposure(id, name, variant, unit: unit)

  defp published(ctx, endpoint) do
    :ok = Context.publish(ctx)

    endpoint
    |> CapturePublisher.events()
    |> Enum.flat_map(& &1["exposures"])
    |> Enum.map(&Map.delete(&1, "exposedAt"))
  end

  defp refresh(ctx, data), do: :ok = Context.refresh(ctx, data)

  # --- two-arm holdouts ------------------------------------------------------

  # heldOutUnitGetsControlValuesAndEmitsNoExposureForCoveredExperiment
  test "a held-out unit gets control and only the holdout's exposure" do
    {ctx, ep} =
      start(data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_in", [11])))

    assert Context.peek(ctx, "exp_holdout_in") == 0
    assert Context.treatment(ctx, "exp_holdout_in") == 0

    assert published(ctx, ep) == [holdout_exposure(11, "holdout_a", 0)]

    [event] = CapturePublisher.events(ep)
    assert event["units"] == [%{"type" => @unit_type, "uid" => ABSmartly.Utils.hash_unit(@uid)}]
  end

  # notHeldOutUnitEmitsHoldoutExposureVariantOneAndNormalExposure
  test "a unit not held out gets its own exposure and the holdout's at arm 1" do
    {ctx, ep} =
      start(data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_out", [11])),
        uid: @uid_not_held_out
      )

    assert Context.treatment(ctx, "exp_holdout_out") == 0

    assert published(ctx, ep) == [
             exposure(1, "exp_holdout_out", 0),
             holdout_exposure(11, "holdout_a", 1)
           ]
  end

  # experimentWithoutHoldoutIdsEmitsNormallyEvenForHeldOutUnit
  test "an experiment without holdoutIds is not covered" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], [
          covered(1, "exp_holdout_in", [11]),
          experiment(2, "exp_not_covered")
        ])
      )

    assert Context.treatment(ctx, "exp_holdout_in") == 0
    assert Context.treatment(ctx, "exp_not_covered") == @normal_variant

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_a", 0),
             exposure(2, "exp_not_covered", @normal_variant)
           ]
  end

  # unionOfApplicableHoldoutsSuppressesExperimentAndBothEmitOwnExposure
  test "either of two holdouts holding the unit out suppresses; both expose" do
    {ctx, ep} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a), holdout(12, "holdout_b", @holdout_b)],
          covered(1, "exp_multi_holdout", [11, 12])
        )
      )

    assert Context.treatment(ctx, "exp_multi_holdout") == 0

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_a", 0),
             holdout_exposure(12, "holdout_b", 1)
           ]
  end

  # unionRuleAppliesWhenTheHigherIdHoldoutIsTheOnlyOneHoldingUnitOut
  test "the union holds when only the higher-id holdout holds the unit out" do
    {ctx, ep} =
      start(
        data(
          [holdout(11, "holdout_low_id", @holdout_b), holdout(12, "holdout_high_id", @holdout_a)],
          covered(1, "exp_union_high_id_decides", [11, 12])
        )
      )

    assert Context.treatment(ctx, "exp_union_high_id_decides") == 0

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_low_id", 1),
             holdout_exposure(12, "holdout_high_id", 0)
           ]
  end

  # unitNotHeldOutByEitherHoldoutIsNotSuppressed
  test "a unit held out by neither holdout is not suppressed" do
    {ctx, ep} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a), holdout(12, "holdout_b", @holdout_b)],
          covered(1, "exp_multi_holdout_miss", [11, 12])
        ),
        uid: @uid_not_held_out
      )

    assert Context.treatment(ctx, "exp_multi_holdout_miss") == 0

    assert published(ctx, ep) == [
             exposure(1, "exp_multi_holdout_miss", 0),
             holdout_exposure(11, "holdout_a", 1),
             holdout_exposure(12, "holdout_b", 1)
           ]
  end

  # holdoutSuppressesFullOnExperimentRegardlessOfFullOnVariant
  test "a holdout suppresses a full-on experiment" do
    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a)],
          covered(1, "exp_fullon_holdout", [11], full_on: 2)
        )
      )

    assert Context.treatment(ctx, "exp_fullon_holdout") == 0
  end

  # --- three-arm holdouts ----------------------------------------------------

  # threeArmVariantZeroHoldsOutBothFullOnAndNonFullOnExperiments
  test "three-arm arm 0 holds out full-on and non-full-on experiments" do
    {ctx, ep} =
      start(
        data([three_arm(21, "holdout_three_arm", @three_arm_0)], [
          covered(1, "exp_three_arm_0_non_fullon", [21]),
          covered(2, "exp_three_arm_0_fullon", [21], full_on: 2)
        ])
      )

    assert Context.treatment(ctx, "exp_three_arm_0_non_fullon") == 0
    assert Context.treatment(ctx, "exp_three_arm_0_fullon") == 0
    assert published(ctx, ep) == [holdout_exposure(21, "holdout_three_arm", 0)]
  end

  # threeArmVariantOneForcesNonFullOnExperimentToControlButAssignsFullOnExperimentNormally
  test "three-arm arm 1 holds out a non-full-on experiment only" do
    {ctx, ep} =
      start(
        data([three_arm(21, "holdout_three_arm", @three_arm_1)], [
          covered(1, "exp_three_arm_1_non_fullon", [21]),
          covered(2, "exp_three_arm_1_fullon", [21], full_on: 2)
        ])
      )

    assert Context.treatment(ctx, "exp_three_arm_1_non_fullon") == 0
    assert Context.treatment(ctx, "exp_three_arm_1_fullon") == 2

    assert published(ctx, ep) == [
             holdout_exposure(21, "holdout_three_arm", 1),
             exposure(2, "exp_three_arm_1_fullon", 2, full_on: true)
           ]
  end

  # threeArmVariantTwoEvaluatesBothExperimentKindsNormally
  test "three-arm arm 2 holds nothing out" do
    {ctx, ep} =
      start(
        data([three_arm(21, "holdout_three_arm", @three_arm_2)], [
          covered(1, "exp_three_arm_2_non_fullon", [21]),
          covered(2, "exp_three_arm_2_fullon", [21], full_on: 2)
        ])
      )

    assert Context.treatment(ctx, "exp_three_arm_2_non_fullon") == @normal_variant
    assert Context.treatment(ctx, "exp_three_arm_2_fullon") == 2

    assert published(ctx, ep) == [
             exposure(1, "exp_three_arm_2_non_fullon", @normal_variant),
             holdout_exposure(21, "holdout_three_arm", 2),
             exposure(2, "exp_three_arm_2_fullon", 2, full_on: true)
           ]
  end

  # twoArmHoldoutWinsUnionEvenWhenThreeArmWouldNotHoldOut
  test "a two-arm holdout wins the union over a three-arm arm 2" do
    {ctx, ep} =
      start(
        data(
          [
            holdout(11, "holdout_two_arm", @holdout_a),
            three_arm(22, "holdout_three_arm", @three_arm_2)
          ],
          covered(1, "exp_union_two_arm_wins", [11, 22])
        )
      )

    assert Context.treatment(ctx, "exp_union_two_arm_wins") == 0

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_two_arm", 0),
             holdout_exposure(22, "holdout_three_arm", 2)
           ]
  end

  # threeArmHoldoutWinsUnionEvenWhenTwoArmWouldNotHoldOut
  test "a three-arm arm 1 wins the union over a two-arm arm 1" do
    {ctx, ep} =
      start(
        data(
          [
            holdout(11, "holdout_two_arm", @holdout_b),
            three_arm(22, "holdout_three_arm", @three_arm_1)
          ],
          covered(1, "exp_union_three_arm_wins", [11, 22])
        )
      )

    assert Context.treatment(ctx, "exp_union_three_arm_wins") == 0

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_two_arm", 1),
             holdout_exposure(22, "holdout_three_arm", 1)
           ]
  end

  # threeArmArmOneDefersToNormalPathSoAudienceMismatchStillWinsForFullOnExperiment
  test "three-arm arm 1 defers a full-on experiment to its strict audience" do
    audience = ~s({"filter":[{"gte":[{"var":"age"},{"value":20}]}]})

    for {seeds, arm} <- [{@three_arm_1, 1}, {@three_arm_2, 2}] do
      {ctx, ep} =
        start(
          data(
            [three_arm(21, "holdout_three_arm", seeds)],
            covered(1, "exp_audience_fullon", [21],
              full_on: 2,
              audience_strict: true,
              audience: audience
            )
          )
        )

      :ok = Context.set_attribute(ctx, "age", 5)

      assert Context.treatment(ctx, "exp_audience_fullon") == 0

      assert published(ctx, ep) == [
               exposure(1, "exp_audience_fullon", 0, assigned: false, audience_mismatch: true),
               holdout_exposure(21, "holdout_three_arm", arm)
             ]
    end
  end

  # Not in ContextHoldoutTest: arity comes from the split, never from
  # holdoutType (scenario 222 only pins arm 0, which holds out at any arity).
  test "the arm count comes from the split, not holdoutType" do
    three_arm_typed_full = three_arm(21, "holdout_three", @three_arm_1, holdout_type: "full")

    three_arm_untyped =
      three_arm(22, "holdout_three_untyped", @three_arm_1) |> Map.delete("holdoutType")

    two_arm_typed_three = holdout(23, "holdout_two", @holdout_b, holdout_type: "all_full_on")

    {ctx, _} =
      start(
        data([three_arm_typed_full, three_arm_untyped, two_arm_typed_three], [
          covered(1, "exp_three_typed_full", [21]),
          covered(2, "exp_three_untyped", [22]),
          covered(3, "exp_two_typed_three", [23])
        ])
      )

    assert Context.treatment(ctx, "exp_three_typed_full") == 0
    assert Context.treatment(ctx, "exp_three_untyped") == 0
    assert Context.treatment(ctx, "exp_two_typed_three") == @normal_variant
  end

  # Not in ContextHoldoutTest (Java keeps duplicates; JS, the reference,
  # dedups them): a duplicated holdout id is one covering holdout.
  test "duplicate holdoutIds are one holdout" do
    {ctx, ep} =
      start(data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_dup", [11, 11, 11])),
        uid: @uid_not_held_out
      )

    assert Context.treatment(ctx, "exp_dup") == 0
    assert Context.pending(ctx) == 2

    refresh(ctx, data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_dup", [11])))
    assert Context.treatment(ctx, "exp_dup") == 0
    assert Context.pending(ctx) == 2

    assert published(ctx, ep) == [exposure(1, "exp_dup", 0), holdout_exposure(11, "holdout_a", 1)]
  end

  # Not in ContextHoldoutTest: exposures follow holdout id order, whatever
  # the order of holdoutIds.
  test "holdout exposures are in id order, not holdoutIds order" do
    {ctx, ep} =
      start(
        data(
          [holdout(12, "holdout_b", @holdout_b), holdout(11, "holdout_a", @holdout_a)],
          covered(1, "exp_order", [12, 11])
        )
      )

    assert Context.treatment(ctx, "exp_order") == 0

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_a", 0),
             holdout_exposure(12, "holdout_b", 1)
           ]
  end

  # Not in ContextHoldoutTest: a same-iteration seed edit is not a coverage
  # change, so a not-held-out experiment is neither re-resolved nor
  # re-exposed (it keeps its variant even when its own split changes).
  test "a same-iteration seed edit does not re-resolve a covered experiment" do
    {ctx, _} =
      start(data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_seed_edit", [11])))

    assert Context.treatment(ctx, "exp_seed_edit") == @normal_variant
    assert Context.pending(ctx) == 2

    refresh(
      ctx,
      data(
        [holdout(11, "holdout_a", {7, 7}, split: [0.2, 0.8])],
        covered(1, "exp_seed_edit", [11], split: [1.0, 0.0])
      )
    )

    assert Context.treatment(ctx, "exp_seed_edit") == @normal_variant
    assert Context.pending(ctx) == 2
  end

  # Not in ContextHoldoutTest: setting another unit type never drops a
  # fully resolved, unexposed covered assignment (which a same-iteration split
  # edit would otherwise move).
  test "set_units adding another unit type keeps a fully resolved assignment" do
    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_b)],
          covered(1, "exp_resolved", [11], unit_type: "user_id")
        ),
        units: %{"user_id" => @uid}
      )

    assert Context.peek(ctx, "exp_resolved") == @normal_variant

    refresh(
      ctx,
      data(
        [holdout(11, "holdout_a", @holdout_b)],
        covered(1, "exp_resolved", [11], unit_type: "user_id", split: [1.0, 0.0])
      )
    )

    :ok = Context.set_units(ctx, %{"session_id" => @uid, "user_id" => @uid})
    assert Context.peek(ctx, "exp_resolved") == @normal_variant
  end

  # Not in ContextHoldoutTest: the control value comes from the first
  # suppressed candidate, even when it lacks the key and a later one has it.
  test "a variable falls back to the first suppressed candidate only" do
    {ctx, _} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], [
          covered(1, "exp_first_suppressed", [11]) |> with_config(1, ~s({"key":"treatment"})),
          covered(2, "exp_second_suppressed", [11]) |> with_config(0, ~s({"key":"control"}))
        ])
      )

    assert Context.peek_variable_value(ctx, "key", "default") == "default"
  end

  # H7 (cross-sdk-tests holdout conformance): a strict audience mismatch on a
  # covered experiment the holdout does not hold out still fires the holdout.
  test "a strict audience mismatch on a covered, not-held-out experiment fires the holdout" do
    experiment =
      covered(1, "exp_h7", [11],
        audience_strict: true,
        audience: ~s({"filter":[{"gte":[{"var":"age"},{"value":20}]}]})
      )

    {ctx, ep} =
      start(data([holdout(11, "holdout_a", @holdout_a)], experiment), uid: @uid_not_held_out)

    :ok = Context.set_attribute(ctx, "age", 5)
    assert Context.treatment(ctx, "exp_h7") == 0

    assert published(ctx, ep) == [
             exposure(1, "exp_h7", 0, assigned: false, audience_mismatch: true),
             holdout_exposure(11, "holdout_a", 1)
           ]
  end

  # Not in ContextHoldoutTest: like the JavaScript SDK, reading an overridden
  # experiment (peek included) fixes the unit's arm, so a same-iteration seed
  # edit before the first exposure cannot move it.
  test "peeking an overridden experiment fixes the holdout arm" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], [
          covered(1, "exp_overridden", [11]),
          covered(2, "exp_sibling", [11])
        ]),
        overrides: %{"exp_overridden" => 1}
      )

    assert Context.peek(ctx, "exp_overridden") == 1

    refresh(
      ctx,
      data([holdout(11, "holdout_a", @holdout_b)], [
        covered(1, "exp_overridden", [11]),
        covered(2, "exp_sibling", [11])
      ])
    )

    assert Context.treatment(ctx, "exp_sibling") == 0
    assert Context.treatment(ctx, "exp_overridden") == 1

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_a", 0),
             exposure(1, "exp_overridden", 1, assigned: false, overridden: true)
           ]
  end

  # Not in ContextHoldoutTest: integral floats are the integers, as in the
  # JavaScript SDK (`11.0` and `11` are the same id, `13.0` the same seed);
  # 11.5 is no id.
  test "integral float seeds preserve both halves when assigning the arm" do
    for seeds <- [{13, 111}, {13.0, 111.0}] do
      {ctx, ep} =
        start(
          data(
            [holdout(11, "holdout_seed", seeds)],
            covered(1, "exp_seed", [11], split: [0.0, 1.0])
          ),
          uid: "float-seed-23"
        )

      assert Context.peek(ctx, "exp_seed") == 0
      assert Context.treatment(ctx, "exp_seed") == 0
      assert published(ctx, ep) == [holdout_exposure(11, "holdout_seed", 0)]
    end
  end

  test "integral float holdout ids, seeds and iterations match integers" do
    {seed_hi, seed_lo} = @holdout_a

    holdout =
      holdout(11, "holdout_a", @holdout_a)
      |> Map.merge(%{"id" => 11.0, "seedHi" => seed_hi * 1.0, "seedLo" => seed_lo * 1.0})
      |> Map.put("iteration", 1.0)

    {ctx, ep} =
      start(
        data([holdout], [
          covered(1, "exp_float_ids", [11.0]),
          covered(2, "exp_fractional_id", [11.5])
        ])
      )

    assert Context.treatment(ctx, "exp_float_ids") == 0
    assert Context.treatment(ctx, "exp_fractional_id") == @normal_variant

    refresh(
      ctx,
      data([holdout(11, "holdout_a", @holdout_a)], [
        covered(1, "exp_float_ids", [11]),
        covered(2, "exp_fractional_id", [11.5])
      ])
    )

    assert Context.treatment(ctx, "exp_float_ids") == 0

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_a", 0),
             exposure(2, "exp_fractional_id", @normal_variant)
           ]
  end

  # Not in ContextHoldoutTest: an experiment without fullOnVariant is not
  # full-on (it randomizes), so arm 1 of a three-arm holdout holds it out.
  test "three-arm arm 1 holds out an experiment without fullOnVariant" do
    experiment = covered(1, "exp_no_full_on", [21]) |> Map.delete("fullOnVariant")

    {ctx, ep} = start(data([three_arm(21, "holdout_three_arm", @three_arm_1)], experiment))

    assert Context.treatment(ctx, "exp_no_full_on") == 0
    assert published(ctx, ep) == [holdout_exposure(21, "holdout_three_arm", 1)]
  end

  # Not in ContextHoldoutTest: pins the JavaScript SDK (javascript-sdk
  # 311cfca, run through the same sequence): the override fast path checks only
  # the variant and the holdout ids/iterations, not unitType, so an exposed
  # overridden experiment whose unit type changes on a refresh is not exposed
  # again, and neither is its holdout for the new unit type.
  test "an overridden experiment whose unit type changes is not re-exposed, as in JS" do
    holdout = holdout(11, "holdout_a", @holdout_b)

    {ctx, ep} =
      start(data([holdout], covered(1, "exp_unit_change", [11])),
        units: %{"session_id" => @uid, "user_id" => @uid},
        overrides: %{"exp_unit_change" => 1}
      )

    assert Context.treatment(ctx, "exp_unit_change") == 1

    refresh(ctx, data([holdout], covered(1, "exp_unit_change", [11], unit_type: "user_id")))

    assert Context.treatment(ctx, "exp_unit_change") == 1

    assert published(ctx, ep) == [
             exposure(1, "exp_unit_change", 1, assigned: false, overridden: true),
             holdout_exposure(11, "holdout_a", 1)
           ]
  end

  # --- missing units and malformed payloads ----------------------------------

  # unconfiguredUnitTypeGetsControlValuesAndEmitsNoExposureAtAll
  test "an experiment whose unit type is not set exposes nothing" do
    {ctx, ep} =
      start(
        data(
          [holdout(11, "holdout_user", @holdout_a, unit_type: "user_id")],
          covered(1, "exp_user_holdout", [11], unit_type: "user_id")
        )
      )

    assert Context.peek(ctx, "exp_user_holdout") == 0
    assert Context.treatment(ctx, "exp_user_holdout") == 0
    assert Context.pending(ctx) == 1

    assert published(ctx, ep) == [
             exposure(1, "exp_user_holdout", 0, assigned: false, unit: "user_id")
           ]
  end

  # assignsNormallyWhenHoldoutsKeyIsAbsent
  test "a payload without holdouts assigns normally" do
    {ctx, _} = start(%{"experiments" => [experiment(1, "exp_no_holdouts_key")]})
    assert Context.peek(ctx, "exp_no_holdouts_key") == @normal_variant
  end

  # holdoutIdAbsentFromHoldoutsArrayIsIgnoredAndExperimentAssignsNormally
  test "a holdout id without a holdout is ignored" do
    {ctx, _} = start(data([], covered(1, "exp_dangling_holdout_id", [999])))
    assert Context.peek(ctx, "exp_dangling_holdout_id") == @normal_variant
  end

  # nullHoldoutArrayElementIsIgnoredAndExperimentAssignsNormally
  test "a null holdout entry is ignored" do
    {ctx, ep} = start(data([nil], experiment(1, "exp_null_holdout_entry")))

    assert Context.treatment(ctx, "exp_null_holdout_entry") == @normal_variant
    assert published(ctx, ep) == [exposure(1, "exp_null_holdout_entry", @normal_variant)]
  end

  # holdoutWithNullSplitIsIgnoredAndExperimentAssignsNormally
  test "a holdout with a null split is ignored" do
    holdout = holdout(11, "holdout_null_split", @holdout_a) |> Map.put("split", nil)
    {ctx, ep} = start(data([holdout], covered(1, "exp_null_split_holdout", [11])))

    assert Context.treatment(ctx, "exp_null_split_holdout") == @normal_variant
    assert published(ctx, ep) == [exposure(1, "exp_null_split_holdout", @normal_variant)]
  end

  # holdoutWithEmptySplitIsIgnoredAndExperimentAssignsNormally
  test "a holdout with an empty split is ignored" do
    holdout = holdout(11, "holdout_empty_split", @holdout_a) |> Map.put("split", [])
    {ctx, ep} = start(data([holdout], covered(1, "exp_empty_split_holdout", [11])))

    assert Context.treatment(ctx, "exp_empty_split_holdout") == @normal_variant
    assert published(ctx, ep) == [exposure(1, "exp_empty_split_holdout", @normal_variant)]
  end

  # setDataDoesNotMutateCallerSuppliedHoldoutIdsArray
  test "unsorted holdoutIds with a dangling id resolve, and the data keeps them" do
    payload =
      data([holdout(11, "holdout_no_mutate", @holdout_a)], [
        covered(1, "exp_holdout_no_mutate_in", [12, 11]),
        experiment(2, "exp_holdout_no_mutate_not_covered")
      ])

    {ctx, _} = start(payload)

    assert Context.treatment(ctx, "exp_holdout_no_mutate_in") == 0
    assert Context.treatment(ctx, "exp_holdout_no_mutate_not_covered") == @normal_variant

    [covered_data | _] = Context.data(ctx).experiments
    assert covered_data.holdout_ids == [12, 11]
  end

  # --- precedence ------------------------------------------------------------

  # customAssignmentCannotOverrideHeldOutVariant
  test "a custom assignment cannot override a held-out variant" do
    {ctx, _} =
      start(data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_custom", [11])),
        custom_assignments: %{"exp_holdout_custom" => 3}
      )

    assert Context.peek(ctx, "exp_holdout_custom") == 0
  end

  # reusesCachedHeldOutAssignmentWithCustomAssignment
  test "a held-out assignment with a custom assignment is reused" do
    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a)],
          covered(1, "exp_holdout_custom_cache", [11])
        ),
        custom_assignments: %{"exp_holdout_custom_cache" => 3}
      )

    assert Context.treatment(ctx, "exp_holdout_custom_cache") == 0
    assert Context.treatment(ctx, "exp_holdout_custom_cache") == 0
    assert Context.pending(ctx) == 1

    :ok = Context.set_custom_assignment(ctx, "exp_holdout_custom_cache", 1)
    assert Context.treatment(ctx, "exp_holdout_custom_cache") == 0
    assert Context.pending(ctx) == 1
    :ok = Context.set_custom_assignments(ctx, %{"exp_holdout_custom_cache" => 0})
    assert Context.treatment(ctx, "exp_holdout_custom_cache") == 0
    assert Context.pending(ctx) == 1
  end

  # overrideTakesPrecedenceOverHoldout
  test "an override wins over a holdout" do
    {ctx, _} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_override", [11])),
        overrides: %{"exp_holdout_override" => 3}
      )

    assert Context.peek(ctx, "exp_holdout_override") == 3
  end

  # getTreatmentOnOverriddenExperimentTriggersApplicableHoldoutExposureBothArms
  test "an overridden experiment still exposes its holdouts, in both arms" do
    for {uid, arm} <- [{@uid, 0}, {@uid_not_held_out, 1}] do
      {ctx, ep} =
        start(
          data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_override", [11])),
          uid: uid,
          overrides: %{"exp_holdout_override" => 3}
        )

      assert Context.treatment(ctx, "exp_holdout_override") == 3

      assert published(ctx, ep) == [
               exposure(1, "exp_holdout_override", 3, assigned: false, overridden: true),
               holdout_exposure(11, "holdout_a", arm)
             ]
    end
  end

  # holdoutTakesPrecedenceOverAudienceMismatch
  test "a holdout wins over a strict audience mismatch" do
    experiment =
      covered(1, "exp_holdout_audience", [11],
        audience_strict: true,
        audience: ~s({"filter":[{"gte":[{"var":"age"},{"value":20}]}]})
      )

    {ctx, ep} = start(data([holdout(11, "holdout_a", @holdout_a)], experiment))
    :ok = Context.set_attribute(ctx, "age", 5)

    assert Context.peek(ctx, "exp_holdout_audience") == 0
    assert Context.treatment(ctx, "exp_holdout_audience") == 0
    assert published(ctx, ep) == [holdout_exposure(11, "holdout_a", 0)]
  end

  # matchingAssignmentRuleWinsOverHoldoutSuppression
  test "a matching assign rule wins over holdout suppression" do
    {ctx, ep} =
      start(
        data(
          [holdout(11, "holdout_rules_suppression", @holdout_a)],
          covered(1, "exp_holdout_rules", [11], rules: @us_rule)
        )
      )

    :ok = Context.set_attribute(ctx, "country", "US")

    assert Context.treatment(ctx, "exp_holdout_rules") == 1

    assert published(ctx, ep) == [
             exposure(1, "exp_holdout_rules", 1, assigned: false, rule_override: true),
             holdout_exposure(11, "holdout_rules_suppression", 0)
           ]

    [event] = CapturePublisher.events(ep)
    assert [%{"name" => "country", "value" => "US"}] = event["attributes"]
  end

  # matchingSplitRuleWinsOverHoldoutSuppression
  test "a matching split rule wins over holdout suppression" do
    rules =
      ~s({"rules":[{"name":"Everyone","type":"split","conditions":null,"environments":[],"percentages":"0/100"}]})

    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a)],
          covered(1, "exp_holdout_split_rule", [11], rules: rules)
        )
      )

    assert Context.peek(ctx, "exp_holdout_split_rule") == 1
    assert Context.treatment(ctx, "exp_holdout_split_rule") == 1
    assert Context.pending(ctx) == 2
  end

  # heldOutUnitIsSuppressedWhenRuleDoesNotMatch
  test "a held-out unit is suppressed until the rule matches" do
    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a)],
          covered(1, "exp_holdout_rules", [11], rules: @us_rule)
        )
      )

    :ok = Context.set_attribute(ctx, "country", "GB")
    assert Context.treatment(ctx, "exp_holdout_rules") == 0
    assert Context.pending(ctx) == 1

    :ok = Context.set_attribute(ctx, "country", "US")
    assert Context.treatment(ctx, "exp_holdout_rules") == 1
    assert Context.pending(ctx) == 2
  end

  # heldOutUnitIsSuppressedAgainWhenRuleStopsMatching
  test "a held-out unit is suppressed again when the rule stops matching" do
    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a)],
          covered(1, "exp_holdout_rules", [11], rules: @us_rule)
        )
      )

    :ok = Context.set_attribute(ctx, "country", "US")
    assert Context.treatment(ctx, "exp_holdout_rules") == 1
    assert Context.pending(ctx) == 2

    :ok = Context.set_attribute(ctx, "country", "GB")
    assert Context.treatment(ctx, "exp_holdout_rules") == 0
    assert Context.peek(ctx, "exp_holdout_rules") == 0
    assert Context.pending(ctx) == 2
  end

  # --- exposure once per holdout ---------------------------------------------

  # holdoutExposureEmittedOncePerContextNotPerSuppressedExperiment
  test "a holdout exposes once for two suppressed experiments" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], [
          covered(1, "exp_shared_a", [11]),
          covered(2, "exp_shared_b", [11])
        ])
      )

    assert Context.treatment(ctx, "exp_shared_a") == 0
    assert Context.treatment(ctx, "exp_shared_b") == 0
    assert published(ctx, ep) == [holdout_exposure(11, "holdout_a", 0)]
  end

  # holdoutExposureFiresOnceEvenWhenTriggeringExperimentIsNotSuppressed
  test "a holdout exposes once for two experiments it does not suppress" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], [
          covered(1, "exp_shared_a", [11]),
          covered(2, "exp_shared_b", [11])
        ]),
        uid: @uid_not_held_out
      )

    Context.treatment(ctx, "exp_shared_a")
    Context.treatment(ctx, "exp_shared_b")

    assert published(ctx, ep) == [
             exposure(1, "exp_shared_a", 0),
             holdout_exposure(11, "holdout_a", 1),
             exposure(2, "exp_shared_b", 0)
           ]
  end

  # reusesCachedSuppressedAssignmentAcrossRepeatedCalls
  test "repeated reads of a suppressed experiment expose once" do
    {ctx, _} =
      start(data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_cache", [11])))

    assert Context.treatment(ctx, "exp_holdout_cache") == 0
    assert Context.treatment(ctx, "exp_holdout_cache") == 0
    assert Context.pending(ctx) == 1
  end

  # oneHoldoutCoveringTwoUnitTypesKeepsIndependentExposureStatePerUnitType
  test "one holdout exposes once per unit type" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_shared", @holdout_b, unit_type: "user_id")], [
          covered(1, "exp_unit_a1", [11], unit_type: "user_id"),
          covered(2, "exp_unit_b", [11], unit_type: "session_id"),
          covered(3, "exp_unit_a2", [11], unit_type: "user_id")
        ]),
        units: %{"user_id" => @uid, "session_id" => @uid}
      )

    assert Context.treatment(ctx, "exp_unit_a1") == @normal_variant
    assert Context.treatment(ctx, "exp_unit_b") == @normal_variant
    assert Context.treatment(ctx, "exp_unit_a2") == @normal_variant
    assert Context.pending(ctx) == 5

    exposures = published(ctx, ep)
    assert length(exposures) == 5

    assert exposures |> Enum.filter(&(&1["id"] == 11)) |> Enum.map(& &1["unit"]) == [
             "user_id",
             "session_id"
           ]
  end

  # --- refresh ---------------------------------------------------------------

  # refreshWithSeedChangeSameIterationKeepsUnitInOriginalArmAndDoesNotReExpose
  test "a same-iteration seed edit keeps the unit's arm and does not re-expose" do
    {ctx, _} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_seed_thrash", [11]))
      )

    assert Context.treatment(ctx, "exp_holdout_seed_thrash") == 0
    assert Context.pending(ctx) == 1

    refresh(
      ctx,
      data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_holdout_seed_thrash", [11]))
    )

    assert Context.treatment(ctx, "exp_holdout_seed_thrash") == 0
    assert Context.pending(ctx) == 1
  end

  # refreshWithCosmeticHoldoutEditDoesNotReExposeHeldOutUnit
  test "a cosmetic holdout edit does not re-expose a held-out unit" do
    {ctx, _} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_cosmetic", [11]))
      )

    assert Context.treatment(ctx, "exp_holdout_cosmetic") == 0
    assert Context.pending(ctx) == 1

    cosmetic =
      holdout(11, "holdout_a_renamed", @holdout_a)
      |> Map.put("applications", [%{"name" => "website"}])
      |> Map.put("variants", variants(["Control", "HeldOut"]))

    refresh(ctx, data([cosmetic], covered(1, "exp_holdout_cosmetic", [11])))

    assert Context.treatment(ctx, "exp_holdout_cosmetic") == 0
    assert Context.pending(ctx) == 1
  end

  # refreshWithCosmeticHoldoutEditDoesNotDuplicateCoveredExperimentExposure
  test "a cosmetic holdout edit does not re-expose the covered experiment" do
    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a)],
          covered(1, "exp_holdout_cosmetic_covered", [11])
        ),
        uid: @uid_not_held_out
      )

    assert Context.treatment(ctx, "exp_holdout_cosmetic_covered") == 0
    assert Context.pending(ctx) == 2

    refresh(
      ctx,
      data(
        [holdout(11, "holdout_a_renamed", @holdout_a)],
        covered(1, "exp_holdout_cosmetic_covered", [11])
      )
    )

    assert Context.treatment(ctx, "exp_holdout_cosmetic_covered") == 0
    assert Context.pending(ctx) == 2
  end

  # refreshWithIterationBumpReassignsToExactlyOneNewArm
  test "an iteration bump reassigns the unit to exactly one new arm" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_holdout_iteration", [11]))
      )

    assert Context.treatment(ctx, "exp_holdout_iteration") == @normal_variant
    assert Context.pending(ctx) == 2

    refresh(
      ctx,
      data(
        [holdout(11, "holdout_a", @holdout_a, iteration: 2)],
        covered(1, "exp_holdout_iteration", [11])
      )
    )

    assert Context.treatment(ctx, "exp_holdout_iteration") == 0
    assert Context.pending(ctx) == 3
    assert Context.treatment(ctx, "exp_holdout_iteration") == 0
    assert Context.pending(ctx) == 3

    assert published(ctx, ep) == [
             exposure(1, "exp_holdout_iteration", @normal_variant),
             holdout_exposure(11, "holdout_a", 1),
             holdout_exposure(11, "holdout_a", 0)
           ]
  end

  # refreshedSeedDoesNotDesyncSuppressionFromPinnedHoldoutArmForNewlyEvaluatedExperiment
  test "a newly evaluated experiment reads the pinned arm, not the new seed" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_holdout_desync_a", [11]))
      )

    assert Context.treatment(ctx, "exp_holdout_desync_a") == 0

    refresh(
      ctx,
      data([holdout(11, "holdout_a", @holdout_b)], [
        covered(1, "exp_holdout_desync_a", [11]),
        covered(2, "exp_holdout_desync_b", [11])
      ])
    )

    assert Context.treatment(ctx, "exp_holdout_desync_b") == 0
    assert Context.treatment(ctx, "exp_holdout_desync_a") == 0
    assert published(ctx, ep) == [holdout_exposure(11, "holdout_a", 0)]
  end

  # refreshFromTwoArmToThreeArmSameIterationDoesNotReinterpretDeferringArmAsFullOnOnly
  test "a same-iteration change from two to three arms keeps the pinned arity" do
    {ctx, ep} =
      start(
        data([holdout(31, "holdout_arity", @holdout_b)], covered(1, "exp_arity_2to3_a", [31]))
      )

    assert Context.treatment(ctx, "exp_arity_2to3_a") == @normal_variant

    refresh(
      ctx,
      data([three_arm(31, "holdout_arity", @three_arm_1)], [
        covered(1, "exp_arity_2to3_a", [31]),
        covered(2, "exp_arity_2to3_b", [31])
      ])
    )

    assert Context.treatment(ctx, "exp_arity_2to3_b") == @normal_variant

    assert published(ctx, ep) == [
             exposure(1, "exp_arity_2to3_a", @normal_variant),
             holdout_exposure(31, "holdout_arity", 1),
             exposure(2, "exp_arity_2to3_b", @normal_variant)
           ]
  end

  # refreshFromThreeArmToTwoArmSameIterationKeepsFullOnOnlyArmSuppressingNonFullOnExperiment
  test "a same-iteration change from three to two arms keeps the pinned arity" do
    {ctx, ep} =
      start(
        data(
          [three_arm(41, "holdout_arity_rev", @three_arm_1)],
          covered(1, "exp_arity_3to2_a", [41])
        )
      )

    assert Context.treatment(ctx, "exp_arity_3to2_a") == 0
    assert Context.pending(ctx) == 1

    refresh(
      ctx,
      data([holdout(41, "holdout_arity_rev", @holdout_b)], [
        covered(1, "exp_arity_3to2_a", [41]),
        covered(2, "exp_arity_3to2_b", [41])
      ])
    )

    assert Context.treatment(ctx, "exp_arity_3to2_b") == 0
    assert published(ctx, ep) == [holdout_exposure(41, "holdout_arity_rev", 1)]
  end

  # experimentsEvaluatedBeforeAndAfterSameIterationArityChangeAgreeOnSuppression
  test "experiments resolved before and after an arity change agree" do
    {ctx, _} =
      start(
        data(
          [holdout(71, "holdout_arity_consistency", @holdout_b)],
          covered(1, "exp_arity_consistency_pre", [71])
        )
      )

    assert Context.treatment(ctx, "exp_arity_consistency_pre") == @normal_variant

    refresh(
      ctx,
      data([three_arm(71, "holdout_arity_consistency", @three_arm_1)], [
        covered(1, "exp_arity_consistency_pre", [71]),
        covered(2, "exp_arity_consistency_post", [71])
      ])
    )

    assert Context.treatment(ctx, "exp_arity_consistency_post") == @normal_variant
    assert Context.treatment(ctx, "exp_arity_consistency_pre") == @normal_variant
  end

  # triggerFiresHoldoutExposureFromDecisionEpochDespiteRefreshRacingBetweenDecisionAndTrigger
  # (a refresh cannot run inside a treatment call here; the exposures come
  # from the arms pinned with the decision, and the next read re-resolves.)
  test "exposures come from the epoch the decision was made in" do
    {ctx, ep} =
      start(data([holdout(11, "holdout_h", @holdout_b)], covered(1, "exp_epoch_race", [11])))

    assert Context.treatment(ctx, "exp_epoch_race") == @normal_variant

    refresh(
      ctx,
      data(
        [holdout(11, "holdout_h", @holdout_a, iteration: 2)],
        covered(1, "exp_epoch_race", [11])
      )
    )

    assert published(ctx, ep) == [
             exposure(1, "exp_epoch_race", @normal_variant),
             holdout_exposure(11, "holdout_h", 1)
           ]
  end

  # staleHoldoutReferenceNeverOverwritesNewerPinnedCacheEntry
  test "an iteration bump exposes each epoch once, never a third time" do
    {ctx, ep} =
      start(data([holdout(11, "holdout_h", @holdout_a)], covered(1, "exp_f", [11])))

    assert Context.treatment(ctx, "exp_f") == 0
    assert Context.pending(ctx) == 1

    refresh(
      ctx,
      data([holdout(11, "holdout_h", @holdout_b, iteration: 2)], [
        covered(1, "exp_f", [11]),
        covered(2, "exp_g", [11])
      ])
    )

    assert Context.treatment(ctx, "exp_g") == @normal_variant
    assert Context.pending(ctx) == 3
    assert Context.treatment(ctx, "exp_f") == @normal_variant
    assert Context.pending(ctx) == 4

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_h", 0),
             exposure(2, "exp_g", @normal_variant),
             holdout_exposure(11, "holdout_h", 1),
             exposure(1, "exp_f", @normal_variant)
           ]
  end

  test "repeated iteration bumps keep holdout exposure state bounded" do
    {ctx, ep} = start(data([holdout(11, "holdout_r", @holdout_b)], covered(1, "exp_r", [11])))

    cycle = fn iteration ->
      refresh(
        ctx,
        data(
          [holdout(11, "holdout_r", @holdout_b, iteration: iteration)],
          covered(1, "exp_r", [11])
        )
      )

      assert Context.treatment(ctx, "exp_r") == @normal_variant
      assert Context.treatment(ctx, "exp_r") == @normal_variant
      assert published(ctx, ep) |> Enum.count(&(&1["name"] == "holdout_r")) == iteration
    end

    Enum.each(1..20, cycle)
    size = :erts_debug.size(:sys.get_state(ctx))
    Enum.each(21..200, cycle)

    assert :erts_debug.size(:sys.get_state(ctx)) == size
  end

  # Not in ContextHoldoutTest: after set_data/2 installs a new iteration on a
  # ready context, the arms of both iterations expose once each, like the
  # JavaScript SDK's per-arm `exposed` flag.
  test "arms of two iterations reachable after set_data each expose once" do
    {ctx, ep} =
      start(data([holdout(11, "holdout_s", @holdout_a)], [covered(1, "exp_a", [11])]))

    assert Context.treatment(ctx, "exp_a") == 0

    :ok =
      Context.set_data(
        ctx,
        data([holdout(11, "holdout_s", @holdout_b, iteration: 2)], [
          covered(1, "exp_a", [11]),
          covered(2, "exp_b", [11])
        ])
      )

    :ok = Context.set_override(ctx, "exp_b", 1)
    assert Context.treatment(ctx, "exp_b") == 1
    :ok = Context.set_override(ctx, "exp_a", nil)
    assert Context.treatment(ctx, "exp_a") == @normal_variant
    :ok = Context.set_override(ctx, "exp_b", 0)
    assert Context.treatment(ctx, "exp_b") == 0

    arms =
      for %{"name" => "holdout_s", "variant" => variant} <- published(ctx, ep), do: variant

    assert arms == [0, 1]
  end

  # Not in ContextHoldoutTest: an arm only the arm cache still holds (its
  # experiment's assignment was dropped by a refresh) keeps its exposure, so
  # re-reading in the same holdout iteration does not expose the holdout again.
  test "a cached arm whose assignment a refresh dropped does not re-expose" do
    {ctx, ep} = start(data([holdout(11, "holdout_c", @holdout_b)], covered(1, "exp_c", [11])))

    assert Context.treatment(ctx, "exp_c") == @normal_variant

    refresh(
      ctx,
      data(
        [holdout(11, "holdout_c", @holdout_b)],
        covered(1, "exp_c", [11]) |> Map.put("iteration", 2)
      )
    )

    assert Context.treatment(ctx, "exp_c") == @normal_variant

    assert published(ctx, ep) |> Enum.map(&{&1["name"], &1["variant"]}) == [
             {"exp_c", @normal_variant},
             {"holdout_c", 1},
             {"exp_c", @normal_variant}
           ]
  end

  # Not in ContextHoldoutTest: an arm only a pinned assignment still holds
  # (the arm cache moved to a newer iteration) keeps its exposure across a
  # later data install.
  test "a pinned arm the cache no longer holds stays exposed across installs" do
    holdouts = fn iteration -> [holdout(11, "holdout_p", @holdout_a, iteration: iteration)] end
    {ctx, ep} = start(data(holdouts.(1), [covered(1, "exp_a", [11])]))

    assert Context.treatment(ctx, "exp_a") == 0
    two = data(holdouts.(2), [covered(1, "exp_a", [11]), covered(2, "exp_b", [11])])
    :ok = Context.set_data(ctx, two)
    assert Context.treatment(ctx, "exp_b") == 0
    :ok = Context.set_data(ctx, two)
    :ok = Context.set_override(ctx, "exp_a", nil)
    assert Context.treatment(ctx, "exp_a") == 0

    arms = for %{"name" => "holdout_p", "variant" => variant} <- published(ctx, ep), do: variant
    assert arms == [0, 0]
  end

  test "repeated set_data iteration bumps keep holdout exposure state bounded" do
    exp = covered(1, "exp_r", [11])
    {ctx, ep} = start(data([holdout(11, "holdout_r", @holdout_b)], exp))

    cycle = fn iteration ->
      :ok =
        Context.set_data(
          ctx,
          data([holdout(11, "holdout_r", @holdout_b, iteration: iteration)], exp)
        )

      :ok = Context.set_override(ctx, "exp_r", 1)
      assert Context.treatment(ctx, "exp_r") == 1
      assert published(ctx, ep) |> Enum.count(&(&1["name"] == "holdout_r")) == iteration
    end

    Enum.each(1..20, cycle)
    size = :erts_debug.size(:sys.get_state(ctx))
    Enum.each(21..200, cycle)

    assert :erts_debug.size(:sys.get_state(ctx)) == size
  end

  # Not in ContextHoldoutTest: as the JavaScript SDK's `holdoutSetMatches`, a
  # covering-holdout change is judged at read time against the holdouts pinned
  # in the assignment, so a change reverted before the next read changes
  # nothing.
  test "a holdout added and removed again between reads does not re-expose" do
    plain = experiment(1, "exp_flip")
    {ctx, ep} = start(data([], plain))

    assert Context.treatment(ctx, "exp_flip") == @normal_variant
    refresh(ctx, data([holdout(11, "holdout_flip", @holdout_a)], covered(1, "exp_flip", [11])))
    refresh(ctx, data([], plain))
    assert Context.treatment(ctx, "exp_flip") == @normal_variant

    assert published(ctx, ep) == [exposure(1, "exp_flip", @normal_variant)]
  end

  test "an overridden experiment's holdout added and removed between reads does not re-expose" do
    plain = experiment(1, "exp_flip_override")
    {ctx, ep} = start(data([], plain), overrides: %{"exp_flip_override" => 1})

    assert Context.treatment(ctx, "exp_flip_override") == 1

    refresh(
      ctx,
      data([holdout(11, "holdout_flip", @holdout_a)], covered(1, "exp_flip_override", [11]))
    )

    refresh(ctx, data([], plain))
    assert Context.treatment(ctx, "exp_flip_override") == 1

    assert published(ctx, ep) == [
             exposure(1, "exp_flip_override", 1, assigned: false, overridden: true)
           ]
  end

  test "coverage added by set_data on a ready context applies at the next read" do
    {ctx, ep} = start(data([], experiment(1, "exp_set_data_cover")))

    assert Context.treatment(ctx, "exp_set_data_cover") == @normal_variant

    :ok =
      Context.set_data(
        ctx,
        data([holdout(11, "holdout_late", @holdout_a)], covered(1, "exp_set_data_cover", [11]))
      )

    assert Context.treatment(ctx, "exp_set_data_cover") == 0

    assert published(ctx, ep) == [
             exposure(1, "exp_set_data_cover", @normal_variant),
             holdout_exposure(11, "holdout_late", 0)
           ]
  end

  # holdoutBecomingApplicableAfterRefreshStillFiresForOverriddenExperiment
  test "a holdout added by a refresh fires for an overridden experiment" do
    {ctx, ep} =
      start(data([], experiment(1, "exp_override_late_holdout")),
        overrides: %{"exp_override_late_holdout" => 3}
      )

    assert Context.treatment(ctx, "exp_override_late_holdout") == 3
    assert Context.pending(ctx) == 1

    refresh(
      ctx,
      data(
        [holdout(11, "holdout_late", @holdout_a)],
        covered(1, "exp_override_late_holdout", [11])
      )
    )

    assert Context.treatment(ctx, "exp_override_late_holdout") == 3
    assert Context.pending(ctx) == 3

    own = exposure(1, "exp_override_late_holdout", 3, assigned: false, overridden: true)
    assert published(ctx, ep) == [own, own, holdout_exposure(11, "holdout_late", 0)]
  end

  # setUnitRedundantCallDoesNotEvictFullyResolvedUnexposedHoldoutSnapshot
  test "a redundant set_unit keeps a resolved, unexposed assignment" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_redundant_set_unit", [11]))
      )

    assert Context.peek(ctx, "exp_redundant_set_unit") == @normal_variant
    assert Context.pending(ctx) == 0

    refresh(
      ctx,
      data(
        [holdout(11, "holdout_a", @holdout_b)],
        covered(1, "exp_redundant_set_unit", [11], split: [1.0, 0.0])
      )
    )

    :ok = Context.set_unit(ctx, @unit_type, @uid)

    assert Context.treatment(ctx, "exp_redundant_set_unit") == @normal_variant

    assert published(ctx, ep) == [
             exposure(1, "exp_redundant_set_unit", @normal_variant),
             holdout_exposure(11, "holdout_a", 1)
           ]
  end

  # --- late units ------------------------------------------------------------

  defp late_unit_context(holdout_seeds, opts \\ []) do
    full_on = Keyword.get(opts, :full_on, 2)

    experiment =
      covered(1, "exp_late", [11], unit_type: "user_id", full_on: full_on)
      |> then(&if(opts[:config], do: with_config(&1, 1, opts[:config]), else: &1))

    start(
      data([holdout(11, "holdout_late", holdout_seeds, unit_type: "user_id")], experiment),
      units: %{},
      overrides: Keyword.get(opts, :overrides, %{}),
      custom_assignments: Keyword.get(opts, :custom_assignments, %{})
    )
  end

  # setUnitInvalidatesNullHoldoutSnapshotSoTheHoldoutExposureIsNotLostForever
  test "set_unit re-resolves an assignment made without the unit" do
    {ctx, ep} = late_unit_context(@holdout_b)

    assert Context.peek(ctx, "exp_late") == 2
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_late") == 2
    assert Context.pending(ctx) == 2

    assert published(ctx, ep) == [
             exposure(1, "exp_late", 2, unit: "user_id", full_on: true),
             holdout_exposure(11, "holdout_late", 1, "user_id")
           ]
  end

  # setUnitDoesNotEvictAlreadyExposedAssignmentSoNoDuplicateExposure
  test "set_unit keeps an exposed assignment made without the unit" do
    {ctx, _} = late_unit_context(@holdout_b)

    assert Context.treatment(ctx, "exp_late") == 2
    assert Context.pending(ctx) == 1
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_late") == 2
    assert Context.pending(ctx) == 1
  end

  # setUnitForUnrelatedUnitTypeDoesNotEvictExposedAssignment
  test "set_unit of another unit type keeps the assignment" do
    {ctx, _} =
      start(data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_unrelated_unit", [11])))

    assert Context.treatment(ctx, "exp_unrelated_unit") == @normal_variant
    assert Context.pending(ctx) == 2
    :ok = Context.set_unit(ctx, "other_unit_type", "some-other-uid")
    assert Context.treatment(ctx, "exp_unrelated_unit") == @normal_variant
    assert Context.pending(ctx) == 2
  end

  # setUnitEvictsOnlyTheAffectedEntryAndLeavesTheOtherUntouched
  test "set_unit re-resolves only the assignments missing that unit" do
    {ctx, _} =
      start(
        data(
          [
            holdout(11, "holdout_late", @holdout_b, unit_type: "user_id"),
            holdout(12, "holdout_present", @holdout_b)
          ],
          [
            covered(1, "exp_late_unit", [11], unit_type: "user_id", full_on: 2),
            covered(2, "exp_present_unit", [12])
          ]
        )
      )

    assert Context.peek(ctx, "exp_late_unit") == 2
    assert Context.treatment(ctx, "exp_present_unit") == @normal_variant
    assert Context.pending(ctx) == 2

    :ok = Context.set_unit(ctx, "user_id", @uid)

    assert Context.treatment(ctx, "exp_late_unit") == 2
    assert Context.pending(ctx) == 4
    assert Context.treatment(ctx, "exp_present_unit") == @normal_variant
    assert Context.pending(ctx) == 4
  end

  # setUnitEvictsUsingTheCoveredExperimentsUnitTypeNotTheHoldoutsDeclaredUnitType
  test "set_unit matches the covered experiment's unit type, not the holdout's" do
    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_declares_b", @holdout_b, unit_type: "B")],
          covered(1, "exp_mismatched_unit_type", [11], unit_type: "A", full_on: 2)
        ),
        units: %{}
      )

    assert Context.peek(ctx, "exp_mismatched_unit_type") == 2
    :ok = Context.set_unit(ctx, "A", @uid)
    assert Context.treatment(ctx, "exp_mismatched_unit_type") == 2
    assert Context.pending(ctx) == 2
  end

  # setUnitRecomputesSuppressionCoherentlyWhenLateResolvedHoldoutSuppresses
  test "set_unit re-resolves suppression when the late holdout holds the unit out" do
    {ctx, ep} = late_unit_context(@holdout_a)

    assert Context.peek(ctx, "exp_late") == 2
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_late") == 0
    assert Context.pending(ctx) == 1
    assert published(ctx, ep) == [holdout_exposure(11, "holdout_late", 0, "user_id")]
  end

  # detachedTreatmentAssignmentCannotPublishBesideSuppressingReplacement
  test "an assignment read before set_unit cannot expose beside its suppressing replacement" do
    {ctx, ep} = late_unit_context(@holdout_a)

    assert Context.peek(ctx, "exp_late") == 2
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_late") == 0
    assert Context.treatment(ctx, "exp_late") == 0
    assert published(ctx, ep) == [holdout_exposure(11, "holdout_late", 0, "user_id")]
  end

  # detachedTreatmentAssignmentRetriesCurrentEntryWithoutLosingExposure
  test "an assignment re-resolved after set_unit keeps both exposures" do
    {ctx, ep} = late_unit_context(@holdout_b)

    assert Context.peek(ctx, "exp_late") == 2
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_late") == 2
    assert Context.pending(ctx) == 2
    assert Context.treatment(ctx, "exp_late") == 2
    assert Context.pending(ctx) == 2

    assert published(ctx, ep) == [
             exposure(1, "exp_late", 2, unit: "user_id", full_on: true),
             holdout_exposure(11, "holdout_late", 1, "user_id")
           ]
  end

  # detachedTreatmentReturnsTheReplacementVariant
  test "treatment after set_unit returns the re-resolved variant" do
    {ctx, _} = late_unit_context(@holdout_a)

    assert Context.peek(ctx, "exp_late") == 2
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_late") == 0
    assert Context.pending(ctx) == 1
  end

  # treatmentExposureSettlesAfterTwoConsecutiveRetirements
  test "each experiment exposes once across repeated reads" do
    {ctx, ep} =
      start(
        data([], [
          experiment(1, "exp_first", full_on: 2),
          experiment(2, "exp_second", full_on: 1),
          experiment(3, "exp_settled", full_on: 1)
        ])
      )

    for _ <- 1..2,
        name <- ["exp_first", "exp_second", "exp_settled"],
        do: Context.treatment(ctx, name)

    assert published(ctx, ep) |> Enum.map(& &1["name"]) == [
             "exp_first",
             "exp_second",
             "exp_settled"
           ]
  end

  # exposureSettlementStopsAfterTheBoundedNumberOfRetirements
  test "peeking never exposes" do
    {ctx, _} = start(data([], experiment(1, "exp_bounded_retry", full_on: 1)))

    for _ <- 1..3, do: assert(Context.peek(ctx, "exp_bounded_retry") == 1)
    assert Context.pending(ctx) == 0
  end

  # detachedVariableAssignmentReresolvesTheKeyToANewWinningExperiment
  test "a variable key re-resolves to a new winning experiment after a refresh" do
    original =
      covered(2, "exp_detached_variable_old", [11], unit_type: "user_id", full_on: 1)
      |> with_config(1, ~s({"detached_var":"old"}))

    holdout = holdout(11, "holdout_detached_variable", @holdout_b, unit_type: "user_id")
    {ctx, ep} = start(data([holdout], original), units: %{})

    assert Context.peek_variable_value(ctx, "detached_var", "default") == "old"
    :ok = Context.set_unit(ctx, "user_id", @uid)

    winner =
      covered(1, "exp_detached_variable_winner", [11], unit_type: "user_id", full_on: 1)
      |> with_config(1, ~s({"detached_var":"new winner"}))

    refresh(ctx, data([holdout], [winner, original]))

    assert Context.variable_value(ctx, "detached_var", "default") == "new winner"
    assert Context.pending(ctx) == 2
    assert Context.variable_value(ctx, "detached_var", "default") == "new winner"
    assert Context.pending(ctx) == 2

    assert published(ctx, ep) == [
             exposure(1, "exp_detached_variable_winner", 1, unit: "user_id", full_on: true),
             holdout_exposure(11, "holdout_detached_variable", 1, "user_id")
           ]
  end

  # triggerApplicableHoldoutExposuresNeverLiveResolvesAPinnedNullEntryForAnAlreadyExposedAssignment
  test "an exposed assignment made without the unit never exposes the holdout later" do
    {ctx, _} =
      late_unit_context(@holdout_a, full_on: 1, config: ~s({"my_var":"value_from_variant"}))

    assert Context.treatment(ctx, "exp_late") == 1
    assert Context.pending(ctx) == 1
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.variable_value(ctx, "my_var", "default") == "value_from_variant"
    assert Context.pending(ctx) == 1
  end

  # setUnitEvictsAssignmentWithMultipleHoldoutsDeclaringDifferentUnitTypes
  test "set_unit re-resolves every holdout of the experiment" do
    {ctx, _} =
      start(
        data(
          [
            holdout(11, "holdout_11", @holdout_b, unit_type: "type_x"),
            holdout(12, "holdout_12", @holdout_b, unit_type: "type_y"),
            holdout(13, "holdout_13", @holdout_b, unit_type: "user_id")
          ],
          covered(1, "exp_multi_holdout_unit_types", [11, 12, 13],
            unit_type: "user_id",
            full_on: 2
          )
        ),
        units: %{}
      )

    assert Context.peek(ctx, "exp_multi_holdout_unit_types") == 2
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_multi_holdout_unit_types") == 2
    assert Context.pending(ctx) == 4
  end

  # setUnitWithNoCachedAssignmentDoesNotThrowAndSubsequentAssignmentIsNormal
  test "set_unit with nothing cached is harmless" do
    {ctx, _} =
      start(
        data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_no_prior_assignment", [11])),
        units: %{}
      )

    :ok = Context.set_unit(ctx, @unit_type, @uid)
    assert Context.treatment(ctx, "exp_no_prior_assignment") == @normal_variant
  end

  # setUnitCalledTwiceWithSameUidIsANoOpAndDoesNotThrow
  test "set_unit with the same uid again changes nothing" do
    {ctx, _} =
      start(data([holdout(11, "holdout_a", @holdout_b)], covered(1, "exp_set_unit_twice", [11])))

    assert Context.treatment(ctx, "exp_set_unit_twice") == @normal_variant
    assert Context.pending(ctx) == 2
    :ok = Context.set_unit(ctx, @unit_type, @uid)
    assert Context.treatment(ctx, "exp_set_unit_twice") == @normal_variant
    assert Context.pending(ctx) == 2
  end

  # peekVariableValueThenSetUnitThenGetVariableValueRecomputesUnderLateSuppressingHoldout
  test "a variable read after set_unit re-resolves under a late suppressing holdout" do
    {ctx, ep} =
      late_unit_context(@holdout_a, full_on: 1, config: ~s({"my_var":"value_from_variant"}))

    assert Context.peek_variable_value(ctx, "my_var", "default") == "value_from_variant"
    assert Context.pending(ctx) == 0
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.variable_value(ctx, "my_var", "default") == "default"
    assert Context.pending(ctx) == 1
    assert published(ctx, ep) == [holdout_exposure(11, "holdout_late", 0, "user_id")]
  end

  # setUnitDoesNotEvictOverrideAssignmentAndHoldoutResolvesLiveAtExposureTime
  test "an overridden experiment exposes a holdout whose unit arrived late" do
    {ctx, ep} =
      late_unit_context(@holdout_b, full_on: 0, overrides: %{"exp_late" => 3})

    assert Context.peek(ctx, "exp_late") == 3
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_late") == 3
    assert Context.pending(ctx) == 2

    assert published(ctx, ep) == [
             exposure(1, "exp_late", 3, unit: "user_id", assigned: false, overridden: true),
             holdout_exposure(11, "holdout_late", 1, "user_id")
           ]
  end

  # setUnitEvictsNullSnapshotForCustomAssignmentAndCustomAppliesAfterRecompute
  test "a custom assignment applies once the late unit is set" do
    {ctx, ep} =
      late_unit_context(@holdout_b, full_on: 0, custom_assignments: %{"exp_late" => 3})

    assert Context.peek(ctx, "exp_late") == 0
    :ok = Context.set_unit(ctx, "user_id", @uid)
    assert Context.treatment(ctx, "exp_late") == 3
    assert Context.pending(ctx) == 2

    assert published(ctx, ep) == [
             exposure(1, "exp_late", 3, unit: "user_id", custom: true),
             holdout_exposure(11, "holdout_late", 1, "user_id")
           ]
  end

  # --- cross-SDK verdict vectors ---------------------------------------------

  defp verdict_context(uid, holdouts) do
    ids = Enum.map(holdouts, & &1["id"])

    start(
      data(
        holdouts,
        covered(9, "verdict_vectors_experiment", ids, unit_type: "verdict_unit_type")
      ),
      units: %{"verdict_unit_type" => uid}
    )
  end

  defp verdict_holdout(id, seeds, split),
    do: holdout(id, "holdout_#{id}", seeds, unit_type: "verdict_unit_type", split: split)

  defp assert_held_out(uid, holdout) do
    {ctx, ep} = verdict_context(uid, [holdout])
    assert Context.treatment(ctx, "verdict_vectors_experiment") == 0

    assert [%{"id" => id, "name" => name, "variant" => 0}] = published(ctx, ep)
    assert {id, name} == {holdout["id"], holdout["name"]}
  end

  defp assert_not_held_out(uid, holdout) do
    {ctx, ep} = verdict_context(uid, [holdout])
    Context.treatment(ctx, "verdict_vectors_experiment")

    assert Enum.any?(
             published(ctx, ep),
             &(&1["id"] == holdout["id"] and &1["name"] == holdout["name"] and &1["variant"] == 1)
           )
  end

  # unicodeUnitIds
  test "unicode unit ids" do
    assert_held_out("façade", verdict_holdout(107, {0, 42}, [0.1, 0.9]))
    assert_not_held_out("unicode_emoji_🚀_0", verdict_holdout(107, {0, 42}, [0.1, 0.9]))
  end

  # signedSeedHalves
  test "seed halves with the sign bit set" do
    seed = -9_223_372_034_707_292_160
    <<seed_hi::signed-32, seed_lo::signed-32>> = <<seed::signed-64>>

    assert_held_out("signed_unit_4", verdict_holdout(106, {seed_hi, seed_lo}, [0.1, 0.9]))
    assert_not_held_out("signed_unit_b_1", verdict_holdout(106, {seed_hi, seed_lo}, [0.1, 0.9]))
  end

  # percentageBoundaryAtOnePercent
  test "a one percent holdout" do
    assert_held_out("pct1_unit_188", verdict_holdout(105, {0, 999_999}, [0.01, 0.99]))
    assert_not_held_out("pct1_unit_0", verdict_holdout(105, {0, 999_999}, [0.01, 0.99]))
  end

  # assignmentProbabilityBoundaryAroundTenPercent
  test "units either side of the ten percent boundary" do
    assert_held_out("boundary_unit_175653", verdict_holdout(107, {0, 42}, [0.1, 0.9]))
    assert_not_held_out("boundary_unit_75792", verdict_holdout(107, {0, 42}, [0.1, 0.9]))
  end

  # unitHeldOutByTwoHoldoutsSimultaneously
  test "a unit held out by two holdouts" do
    {ctx, ep} =
      verdict_context("dual_holdout_unit_5", [
        verdict_holdout(107, {0, 42}, [0.1, 0.9]),
        verdict_holdout(108, {0, 55}, [0.1, 0.9])
      ])

    assert Context.treatment(ctx, "verdict_vectors_experiment") == 0

    assert published(ctx, ep) == [
             holdout_exposure(107, "holdout_107", 0, "verdict_unit_type"),
             holdout_exposure(108, "holdout_108", 0, "verdict_unit_type")
           ]
  end

  # --- variables -------------------------------------------------------------

  # variableLookupFiresHoldoutExposureForBothHeldOutAndNonHeldOutUnits
  test "a variable read exposes the holdout, held out or not" do
    experiment = covered(1, "exp_var", [11]) |> with_config(1, ~s({"var_a":"value_a"}))

    {held_out, _} = start(data([holdout(11, "holdout_a", @holdout_a)], experiment))
    assert Context.variable_value(held_out, "var_a", "default") == "default"
    assert Context.pending(held_out) == 1

    {not_held_out, _} =
      start(data([holdout(11, "holdout_a", @holdout_a)], experiment), uid: @uid_not_held_out)

    assert Context.variable_value(not_held_out, "var_a", "default") == "default"
    assert Context.pending(not_held_out) == 2
  end

  # variableKeyResolutionSkipsSuppressedAssignmentInFavorOfAssignedOne
  test "a suppressed experiment never wins a variable key over an assigned one" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], [
          covered(1, "exp_var_key_suppressed", [11])
          |> with_config(1, ~s({"shared":"from_suppressed"})),
          experiment(2, "exp_var_key_assigned") |> with_config(1, ~s({"shared":"from_assigned"}))
        ])
      )

    assert Context.variable_value(ctx, "shared", "default") == "from_assigned"

    assert published(ctx, ep) == [
             holdout_exposure(11, "holdout_a", 0),
             exposure(2, "exp_var_key_assigned", @normal_variant)
           ]
  end

  # peekVariableValueNeverTriggersHoldoutExposureForEvaluatedCandidates
  test "peek_variable_value exposes nothing" do
    {ctx, _} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], [
          covered(1, "exp_var_key_peek_suppressed", [11])
          |> with_config(1, ~s({"shared_peek":"from_suppressed"})),
          experiment(2, "exp_var_key_peek_assigned")
          |> with_config(1, ~s({"shared_peek":"from_assigned"}))
        ])
      )

    assert Context.peek_variable_value(ctx, "shared_peek", "default") == "from_assigned"
    assert Context.pending(ctx) == 0
  end

  # variableValueOnHeldOutRuleWonExperiment
  test "a variable read of a rule-won held-out experiment" do
    experiment =
      covered(1, "exp_holdout_rules", [11], rules: @us_rule) |> with_variables("color")

    {ctx, ep} = start(data([holdout(11, "holdout_rules_suppression", @holdout_a)], experiment))
    :ok = Context.set_attribute(ctx, "country", "US")

    assert Context.variable_value(ctx, "color", "default") == "treatment"

    assert published(ctx, ep) == [
             exposure(1, "exp_holdout_rules", 1, assigned: false, rule_override: true),
             holdout_exposure(11, "holdout_rules_suppression", 0)
           ]
  end

  # sharedVariableKeyPrefersRuleWonOverSuppressedExperiment
  test "a shared variable key prefers a rule-won experiment over a suppressed one" do
    {ctx, _} =
      start(
        data([holdout(11, "holdout_a", @holdout_a)], [
          covered(1, "exp_held_out", [11]) |> with_variables("color"),
          covered(2, "exp_rule_won", [11], rules: @us_rule) |> with_variables("color")
        ])
      )

    :ok = Context.set_attribute(ctx, "country", "GB")
    assert Context.peek_variable_value(ctx, "color", "default") == "control"
    :ok = Context.set_attribute(ctx, "country", "US")
    assert Context.peek_variable_value(ctx, "color", "default") == "treatment"
  end

  # sharedVariableKeyPrefersEarlierAssignedOverLaterRuleWonExperiment
  test "a shared variable key prefers an earlier assigned experiment over a rule-won one" do
    {ctx, _} =
      start(
        data([], [
          experiment(1, "exp_assigned", split: [1.0, 0.0]) |> with_variables("color"),
          experiment(2, "exp_rule_won", rules: @us_rule) |> with_variables("color")
        ])
      )

    :ok = Context.set_attribute(ctx, "country", "US")
    assert Context.peek_variable_value(ctx, "color", "default") == "control"
    assert Context.peek(ctx, "exp_rule_won") == 1
  end

  # --- event handler failures ------------------------------------------------

  defp raising_handler(fun) do
    fn type, data -> if fun.(type, data), do: raise("boom") end
  end

  # throwingLoggerDoesNotPermanentlyLoseSiblingHoldoutExposure
  test "a crashing event handler does not lose a sibling holdout exposure" do
    handler = raising_handler(&(&1 == :exposure and &2.id == 11))

    {ctx, _} =
      start(
        data(
          [holdout(11, "holdout_a", @holdout_a), holdout(12, "holdout_b", @holdout_b)],
          covered(1, "exp_multi_holdout_throwing_logger", [11, 12])
        ),
        event_handler: handler
      )

    Context.treatment(ctx, "exp_multi_holdout_throwing_logger")
    assert Context.pending(ctx) == 2
  end

  # throwingLoggerDoesNotMakeExperimentOrHoldoutExposureRetryable
  test "a crashing event handler does not make exposures repeat" do
    handler = raising_handler(&(&1 == :exposure and &2.id == 1))

    {ctx, ep} =
      start(
        data([holdout(11, "holdout_terminal", @holdout_b)], covered(1, "exp_terminal", [11])),
        event_handler: handler
      )

    Context.treatment(ctx, "exp_terminal")
    assert Context.treatment(ctx, "exp_terminal") == @normal_variant

    assert published(ctx, ep) == [
             exposure(1, "exp_terminal", @normal_variant),
             holdout_exposure(11, "holdout_terminal", 1)
           ]
  end

  # throwingLoggerOnSuppressedExperimentsOnlyHoldoutStillSchedulesFlush
  test "a crashing event handler still leaves the only holdout exposure to publish" do
    handler = raising_handler(fn type, _ -> type == :exposure end)

    {ctx, ep} =
      start(data([holdout(11, "holdout_a", @holdout_a)], covered(1, "exp_stranded_flush", [11])),
        event_handler: handler
      )

    Context.treatment(ctx, "exp_stranded_flush")
    assert Context.pending(ctx) == 1
    assert published(ctx, ep) == [holdout_exposure(11, "holdout_a", 0)]
  end

  # variablePathHoldoutExposureSchedulesFlushWithoutAnyOtherEvent
  test "a holdout exposure from a losing variable candidate is published" do
    {ctx, ep} =
      start(
        data([holdout(11, "holdout_flush", @holdout_a)], [
          covered(1, "exp_var_flush_suppressed", [11])
          |> with_config(1, ~s({"flush_key":"from_suppressed"})),
          experiment(2, "exp_var_flush_assigned")
          |> with_config(1, ~s({"flush_key":"from_assigned"}))
        ])
      )

    assert Context.peek(ctx, "exp_var_flush_assigned") == @normal_variant
    assert Context.variable_value(ctx, "flush_key", "default") == "from_assigned"
    assert holdout_exposure(11, "holdout_flush", 0) in published(ctx, ep)
  end
end
