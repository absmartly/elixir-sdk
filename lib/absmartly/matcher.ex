defmodule ABSmartly.Matcher do
  @moduledoc """
  Audience matcher for experiment targeting.

  Fixes HIGH-07: Returns `true` for unrecognized filters.
  """

  alias ABSmartly.JSONExpr.Evaluator

  require Logger

  @doc """
  Evaluate audience filter against attributes.

  Returns:
  - nil if filter is nil
  - true if filter is empty map (matches all)
  - result of filter evaluation otherwise
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
        # Fixes HIGH-07: Check if %{"invalid" => true} sentinel from parse_audience
        if Map.get(filter, "invalid") == true do
          Logger.error("Invalid audience filter detected")
          false
        else
          true
        end

      filter_expr when is_list(filter_expr) ->
        # Convert attributes to a map for JSONExpr evaluation
        vars = attributes_to_vars(attributes)

        # Filter is an array of expressions (OR logic)
        Enum.any?(filter_expr, fn expr ->
          case Evaluator.evaluate(expr, vars) do
            true -> true
            _ -> false
          end
        end)

      other ->
        # Fixes HIGH-07: Log and fail closed for non-list filter
        Logger.error("Filter key is not a list: #{inspect(other)}")
        false
    end
  end

  # Fixes HIGH-07: Fail closed for invalid filter types
  def evaluate(filter, _attributes) do
    Logger.error("Invalid filter type: #{inspect(filter)}")
    false
  end

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
