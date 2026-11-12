defmodule ABSmartly.Matcher do
  @moduledoc """
  Audience matcher for experiment targeting.
  """

  alias ABSmartly.JSONExpr.Evaluator

  require Logger

  @doc """
  Evaluate audience filter against attributes.

  Returns:
  - nil if filter is nil
  - true if filter is empty map (matches all)
  - result of filter evaluation otherwise
  - nil when the filter value is not a list or map
  - false for invalid filter structures (fail closed)

  ## Examples

      iex> evaluate(nil, %{})
      nil

      iex> evaluate(%{}, %{})
      true

      iex> evaluate(%{"filter" => [%{"value" => true}]}, %{})
      true

      iex> evaluate(%{"filter" => [%{"value" => false}]}, %{})
      false
  """
  def evaluate(nil, _attributes), do: nil
  def evaluate(filter, _attributes) when map_size(filter) == 0, do: true

  def evaluate(filter, attributes) when is_map(filter) do
    case Map.get(filter, "filter") do
      nil ->
        if Map.get(filter, "invalid") == true do
          Logger.error("Invalid audience filter detected")
          false
        else
          true
        end

      filter_expr when is_list(filter_expr) or is_map(filter_expr) ->
        vars = attributes_to_vars(attributes)

        Evaluator.evaluate(filter_expr, vars) == true

      other ->
        # Like the JavaScript SDK: a filter that is neither an array nor an
        # object cannot be evaluated, so it is neither a match nor a mismatch.
        Logger.error("Filter key is not a list or map: #{inspect(other)}")
        nil
    end
  end

  def evaluate(filter, _attributes) do
    Logger.error("Invalid filter type: #{inspect(filter)}")
    false
  end

  @split_sum_tolerance 0.01

  @doc """
  Parse an experiment's `assignmentRules` JSON into its list of rules.

  Returns nil when the value is absent, not valid JSON or not an object with a
  `rules` list, in which case the experiment has no rules.
  """
  def parse_rules(rules) when is_binary(rules) and rules != "" do
    case Jason.decode(rules) do
      {:ok, %{"rules" => rules}} when is_list(rules) ->
        rules

      {:ok, _} ->
        nil

      {:error, error} ->
        Logger.error("Failed to parse assignmentRules JSON: #{inspect(error)}")
        nil
    end
  end

  def parse_rules(_rules), do: nil

  @doc """
  Return the action of the first rule that matches `environment` and
  `attributes`: `{:variant, variant}` for an `assign` rule, `{:split, fractions}`
  for a `split` rule, or nil when no rule matches.

  Mirrors the JavaScript SDK's `evaluateParsedRules` (src/matcher.ts): a rule
  whose action is invalid (unknown type, non-integer variant, or percentages
  that are not non-negative numbers summing to 100) is skipped. An
  `environments` list, when present, must contain `environment` unless it is
  empty. Absent conditions always match; otherwise they must be an object that
  evaluates to true. Bounds checking the action is the caller's job.
  """
  def evaluate_rules(nil, _environment, _attributes), do: nil

  def evaluate_rules(rules, environment, attributes) when is_list(rules) do
    vars = attributes_to_vars(attributes)
    Enum.find_value(rules, &evaluate_rule(&1, environment, vars))
  end

  defp evaluate_rule(rule, environment, vars) when is_map(rule) do
    with action when action != nil <- rule_action(rule),
         true <- environment_matches?(rule["environments"], environment),
         true <- conditions_match?(rule, vars) do
      action
    else
      _ -> nil
    end
  end

  defp evaluate_rule(_rule, _environment, _vars), do: nil

  defp rule_action(%{"type" => "assign", "variant" => variant}) when is_integer(variant),
    do: {:variant, variant}

  defp rule_action(%{"type" => "split", "percentages" => percentages}),
    do: parse_split(percentages)

  defp rule_action(_rule), do: nil

  defp environment_matches?(nil, _environment), do: true
  defp environment_matches?([], _environment), do: true

  defp environment_matches?(environments, environment) when is_list(environments),
    do: environment != nil and environment in environments

  defp environment_matches?(_environments, _environment), do: false

  defp conditions_match?(rule, vars) do
    case rule["conditions"] do
      nil ->
        true

      conditions when is_map(conditions) ->
        try do
          Evaluator.boolean_convert(Evaluator.evaluate(conditions, vars)) == true
        rescue
          error ->
            Logger.warning(
              "Failed to evaluate assignment rule conditions for rule #{inspect(rule["name"])}: " <>
                Exception.message(error)
            )

            false
        end

      _ ->
        false
    end
  end

  # Same parsing as the JavaScript SDK (`parseFloat` per `/`-separated value)
  # and the same sum check as the backend's experiment split: the gap from 100
  # is rounded to two decimals before being compared with 0.01.
  defp parse_split(percentages) when is_binary(percentages) do
    values = percentages |> String.split("/") |> Enum.map(&Evaluator.number_convert/1)

    if Enum.all?(values, &(is_number(&1) and &1 >= 0)) do
      gap = abs(100 - Enum.sum(values)) |> ABSmartly.Utils.number_to_fixed(2)

      if Evaluator.number_convert(gap) <= @split_sum_tolerance,
        do: {:split, Enum.map(values, &(&1 / 100))}
    end
  end

  defp parse_split(_percentages), do: nil

  defp attributes_to_vars(attributes) when is_list(attributes) do
    Enum.reduce(attributes, %{}, fn attr, acc ->
      case attr do
        %{"name" => name, "value" => value} ->
          Map.put(acc, name, value)

        {name, value} ->
          Map.put(acc, to_string(name), value)

        _ ->
          acc
      end
    end)
  end

  defp attributes_to_vars(attributes) when is_map(attributes) do
    attributes
  end

  defp attributes_to_vars(_), do: %{}
end
