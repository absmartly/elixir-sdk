defmodule ABSmartly.AssignmentRules do
  @moduledoc false
  # Resolves an experiment's assignment rules to a variant. The context owns
  # the parsed-rules cache, the cached assignments and when to re-check them.

  alias ABSmartly.{Matcher, Utils, VariantAssigner}

  @doc """
  Parse an experiment's `assignmentRules` JSON once, when its data is
  installed. Returns nil when the experiment has no usable rules.
  """
  defdelegate parse(assignment_rules), to: Matcher, as: :parse_rules

  @doc """
  Returns `{variant, missing_unit}` from the first matching rule, or
  `{nil, false}` when no rule applies. `uid` is the experiment's unit (nil when
  it is missing, or when an exposed split must stay pinned to its missing-unit
  variant).

  As in the JavaScript SDK's `_resolveRule`, an unusable first match (an
  out-of-range variant, or a split without one percentage per variant) falls
  back to normal assignment rather than trying later rules.
  """
  def resolve(nil, _experiment, _environment, _vars, _uid), do: {nil, false}

  def resolve(rules, experiment, environment, vars, uid) do
    variant_count = length(experiment.variants || [])

    case Matcher.evaluate_rules(rules, environment, vars) do
      {:variant, variant} when variant >= 0 and variant < variant_count ->
        {variant, false}

      {:split, split} when length(split) == variant_count ->
        if uid == nil do
          {missing_unit_variant(experiment.full_on_variant, variant_count), true}
        else
          hashed_unit = Utils.hash_unit(uid)

          variant =
            VariantAssigner.assign(hashed_unit, split, experiment.seed_hi, experiment.seed_lo)

          {variant, false}
        end

      _ ->
        {nil, false}
    end
  end

  # The full-on variant, or 0 (control) when the experiment is not full-on or
  # its full-on variant is not one of its variants.
  defp missing_unit_variant(full_on_variant, variant_count)
       when is_integer(full_on_variant) and full_on_variant > 0 and
              full_on_variant < variant_count,
       do: full_on_variant

  defp missing_unit_variant(_full_on_variant, _variant_count), do: 0
end
