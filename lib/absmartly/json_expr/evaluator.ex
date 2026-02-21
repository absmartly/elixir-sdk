defmodule ABSmartly.JSONExpr.Evaluator do
  @moduledoc """
  JSON expression evaluator for audience targeting.

  Supports 13 operators: and, or, not, null, var, value, eq, gt, gte, lt, lte, in, match

  Fixes:
  - CRITICAL-04: ReDoS vulnerability in eval_match
  - HIGH-10: ReDoS risk + silent regex compilation failure
  - HIGH-14: Non-list `and`/`or` silently defaults
  - MEDIUM-21: Unknown operators silently return nil
  """

  alias ABSmartly.Utils

  require Logger

  # Maximum regex pattern length (CRITICAL-04)
  @max_regex_length 1000
  # Regex timeout in milliseconds (CRITICAL-04)
  @regex_timeout_ms 100

  @doc """
  Evaluate a JSON expression with given variables.

  ## Examples

      iex> evaluate(%{"value" => true}, %{})
      true

      iex> evaluate(%{"var" => "age"}, %{"age" => 25})
      25

      iex> evaluate(%{"eq" => [%{"var" => "age"}, 25]}, %{"age" => 25})
      true
  """
  def evaluate(nil, _vars), do: nil

  def evaluate(expr, vars) when is_list(expr) do
    eval_and(expr, vars)
  end

  def evaluate(expr, vars) when is_map(expr) do
    cond do
      Map.has_key?(expr, "and") -> eval_and(expr["and"], vars)
      Map.has_key?(expr, "or") -> eval_or(expr["or"], vars)
      Map.has_key?(expr, "not") -> eval_not(expr["not"], vars)
      Map.has_key?(expr, "null") -> eval_null(expr["null"], vars)
      Map.has_key?(expr, "var") -> eval_var(expr["var"], vars)
      Map.has_key?(expr, "value") -> expr["value"]
      Map.has_key?(expr, "eq") -> eval_eq(expr["eq"], vars)
      Map.has_key?(expr, "gt") -> eval_gt(expr["gt"], vars)
      Map.has_key?(expr, "gte") -> eval_gte(expr["gte"], vars)
      Map.has_key?(expr, "lt") -> eval_lt(expr["lt"], vars)
      Map.has_key?(expr, "lte") -> eval_lte(expr["lte"], vars)
      Map.has_key?(expr, "in") -> eval_in(expr["in"], vars)
      Map.has_key?(expr, "match") -> eval_match(expr["match"], vars)
      # Fixes MEDIUM-21: Log unknown operators
      true ->
        Logger.warning("Unknown operator in expression: #{inspect(Map.keys(expr))}")
        nil
    end
  end

  def evaluate(_value, _vars), do: nil

  # Operator implementations

  # Fixes HIGH-14: Validate that and/or receive lists, fail closed if not
  defp eval_and(exprs, vars) when is_list(exprs) do
    Enum.reduce_while(exprs, true, fn expr, _acc ->
      case Utils.to_boolean(evaluate(expr, vars)) do
        false -> {:halt, false}
        nil -> {:halt, nil}
        _ -> {:cont, true}
      end
    end)
  end

  defp eval_and(exprs, _vars) do
    Logger.error("Invalid 'and' operand (expected list): #{inspect(exprs)}")
    false
  end

  defp eval_or(exprs, vars) when is_list(exprs) do
    Enum.reduce_while(exprs, false, fn expr, _acc ->
      case Utils.to_boolean(evaluate(expr, vars)) do
        true -> {:halt, true}
        nil -> {:halt, nil}
        _ -> {:cont, false}
      end
    end)
  end

  defp eval_or(exprs, _vars) do
    Logger.error("Invalid 'or' operand (expected list): #{inspect(exprs)}")
    false
  end

  defp eval_not(expr, vars) do
    case Utils.to_boolean(evaluate(expr, vars)) do
      nil -> nil
      bool -> !bool
    end
  end

  defp eval_null(expr, vars) do
    evaluate(expr, vars) == nil
  end

  defp eval_var(path, vars) when is_binary(path) do
    path
    |> String.split("/")
    |> get_nested(vars)
  end

  defp eval_var(_path, _vars), do: nil

  defp get_nested([], value), do: value
  defp get_nested(_path, nil), do: nil

  defp get_nested([key | rest], value) when is_map(value) do
    get_nested(rest, Map.get(value, key))
  end

  defp get_nested([key | rest], value) when is_list(value) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 and index < length(value) ->
        get_nested(rest, Enum.at(value, index))

      _ ->
        nil
    end
  end

  defp get_nested(_path, _value), do: nil

  defp eval_eq([lhs_expr, rhs_expr], vars) do
    lhs = evaluate(lhs_expr, vars)
    rhs = evaluate(rhs_expr, vars)

    case compare(lhs, rhs) do
      0 -> true
      nil -> false
      _ -> false
    end
  end

  defp eval_eq(_args, _vars), do: false

  defp eval_gt([lhs_expr, rhs_expr], vars) do
    lhs = evaluate(lhs_expr, vars)
    rhs = evaluate(rhs_expr, vars)

    case compare(lhs, rhs) do
      cmp when is_integer(cmp) and cmp > 0 -> true
      _ -> false
    end
  end

  defp eval_gt(_args, _vars), do: false

  defp eval_gte([lhs_expr, rhs_expr], vars) do
    lhs = evaluate(lhs_expr, vars)
    rhs = evaluate(rhs_expr, vars)

    case compare(lhs, rhs) do
      cmp when is_integer(cmp) and cmp >= 0 -> true
      _ -> false
    end
  end

  defp eval_gte(_args, _vars), do: false

  defp eval_lt([lhs_expr, rhs_expr], vars) do
    lhs = evaluate(lhs_expr, vars)
    rhs = evaluate(rhs_expr, vars)

    case compare(lhs, rhs) do
      cmp when is_integer(cmp) and cmp < 0 -> true
      _ -> false
    end
  end

  defp eval_lt(_args, _vars), do: false

  defp eval_lte([lhs_expr, rhs_expr], vars) do
    lhs = evaluate(lhs_expr, vars)
    rhs = evaluate(rhs_expr, vars)

    case compare(lhs, rhs) do
      cmp when is_integer(cmp) and cmp <= 0 -> true
      _ -> false
    end
  end

  defp eval_lte(_args, _vars), do: false

  defp eval_in([needle_expr, haystack_expr], vars) do
    needle = evaluate(needle_expr, vars)
    haystack = evaluate(haystack_expr, vars)

    cond do
      is_nil(needle) or is_nil(haystack) ->
        false

      is_binary(haystack) and is_binary(needle) ->
        String.contains?(haystack, needle)

      is_list(haystack) ->
        Enum.any?(haystack, fn item ->
          case compare(item, needle) do
            0 -> true
            _ -> false
          end
        end)

      true ->
        false
    end
  end

  defp eval_in(_args, _vars), do: false

  # Fixes CRITICAL-04, HIGH-10: ReDoS protection with pattern validation and timeout
  defp eval_match([text_expr, pattern_expr], vars) do
    text = evaluate(text_expr, vars)
    pattern = evaluate(pattern_expr, vars)

    cond do
      is_nil(text) or is_nil(pattern) ->
        false

      is_binary(text) and is_binary(pattern) ->
        # Fixes CRITICAL-04: Reject patterns that are too long
        if String.length(pattern) > @max_regex_length do
          Logger.warning(
            "Regex pattern too long (#{String.length(pattern)}), rejecting: #{String.slice(pattern, 0, 100)}..."
          )

          false
        else
          case Regex.compile(pattern) do
            {:ok, regex} ->
              # Fixes CRITICAL-04: Run regex in a Task with timeout
              task = Task.async(fn -> Regex.match?(regex, text) end)

              case Task.yield(task, @regex_timeout_ms) || Task.shutdown(task) do
                {:ok, result} ->
                  result

                nil ->
                  Logger.error(
                    "Regex timeout (#{@regex_timeout_ms}ms): pattern=#{pattern}, text=#{String.slice(text, 0, 100)}"
                  )

                  false
              end

            {:error, reason} ->
              # Fixes HIGH-10: Log regex compilation failures
              Logger.error("Invalid regex pattern: #{pattern}, reason: #{inspect(reason)}")
              false
          end
        end

      true ->
        false
    end
  end

  defp eval_match(_args, _vars), do: false

  @doc """
  Compare two values.

  Returns:
  - 0 if equal
  - 1 if lhs > rhs
  - -1 if lhs < rhs
  - nil if not comparable
  """
  def compare(nil, nil), do: 0
  def compare(nil, _), do: nil
  def compare(_, nil), do: nil

  def compare(lhs, rhs) when is_boolean(lhs) and is_boolean(rhs) do
    cond do
      lhs == rhs -> 0
      lhs -> 1
      true -> -1
    end
  end

  def compare(lhs, rhs) when is_number(lhs) and is_number(rhs) do
    cond do
      lhs == rhs -> 0
      lhs > rhs -> 1
      true -> -1
    end
  end

  def compare(lhs, rhs) when is_binary(lhs) and is_binary(rhs) do
    cond do
      lhs == rhs -> 0
      lhs > rhs -> 1
      true -> -1
    end
  end

  def compare(lhs, rhs) when (is_list(lhs) or is_map(lhs)) and (is_list(rhs) or is_map(rhs)) do
    case {Jason.encode(lhs), Jason.encode(rhs)} do
      {{:ok, lhs_json}, {:ok, rhs_json}} ->
        cond do
          lhs_json == rhs_json -> 0
          lhs_json > rhs_json -> 1
          true -> -1
        end

      _ ->
        Logger.warning("Failed to compare complex values via JSON encoding")
        nil
    end
  end

  def compare(_lhs, _rhs), do: nil
end
