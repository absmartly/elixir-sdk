defmodule ABSmartly.JSONExpr.Evaluator do
  @moduledoc """
  JSON expression evaluator for audience targeting.

  Mirrors the JavaScript SDK's `jsonexpr` (src/jsonexpr): the same operators,
  the same type conversions and the same `null` results. Supported operators:
  and, or, not, null, var, value, eq, gt, gte, lt, lte, in, match, plus
  `contains` (an alias of `in`, haystack first).

  - A list expression is an implicit `and`; a map expression is dispatched on
    its operator key; anything else evaluates to `nil`.
  - Binary operators return `nil` when either operand is `nil`.
  - `in`/`contains` take `[haystack, needle]`: a list haystack matches an
    element that compares equal, a string haystack matches a substring (the
    needle is converted to a string) and a map haystack matches a key. Any
    other haystack gives `nil`.
  - `match` gives `nil` for an invalid (or over-long) regular expression.
  """

  require Logger

  @max_regex_length 1000
  @regex_timeout_ms 100

  @binary_operators ~w(eq gt gte lt lte in contains match)

  @doc """
  Evaluate a JSON expression with given variables.

  ## Examples

      iex> evaluate(%{"value" => true}, %{})
      true

      iex> evaluate(%{"var" => "age"}, %{"age" => 25})
      25

      iex> evaluate(%{"eq" => [%{"var" => "age"}, %{"value" => 25}]}, %{"age" => 25})
      true
  """
  def evaluate(expr, vars) when is_list(expr), do: eval_and(expr, vars)

  def evaluate(expr, vars) when is_map(expr) and map_size(expr) > 0 do
    [{op, args} | _] = Map.to_list(expr)

    case op do
      "and" ->
        eval_and(args, vars)

      "or" ->
        eval_or(args, vars)

      "not" ->
        not boolean_convert(evaluate(args, vars))

      "null" ->
        evaluate(args, vars) == nil

      "var" ->
        eval_var(args, vars)

      "value" ->
        args

      op when op in @binary_operators ->
        eval_binary(op, args, vars)

      _ ->
        Logger.warning("Unknown operator in expression: #{inspect(op)}")
        nil
    end
  end

  def evaluate(_expr, _vars), do: nil

  defp eval_and(exprs, vars) when is_list(exprs) do
    Enum.all?(exprs, &boolean_convert(evaluate(&1, vars)))
  end

  defp eval_and(_exprs, _vars), do: nil

  defp eval_or([], _vars), do: true

  defp eval_or(exprs, vars) when is_list(exprs) do
    Enum.any?(exprs, &boolean_convert(evaluate(&1, vars)))
  end

  defp eval_or(_exprs, _vars), do: nil

  defp eval_var(%{"path" => path}, vars), do: eval_var(path, vars)

  defp eval_var(path, vars) when is_binary(path) do
    path
    |> String.split("/")
    |> get_nested(vars || %{})
  end

  defp eval_var(_path, _vars), do: nil

  defp get_nested([], value), do: value

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

  # Binary operators evaluate the left operand first and return nil without
  # evaluating the right one when it is nil (JS operators/binary.ts).
  defp eval_binary(op, args, vars) when is_list(args) do
    lhs = evaluate(Enum.at(args, 0), vars)

    if lhs == nil do
      nil
    else
      rhs = evaluate(Enum.at(args, 1), vars)
      if rhs == nil, do: nil, else: binary(op, lhs, rhs)
    end
  end

  defp eval_binary(_op, _args, _vars), do: nil

  defp binary("eq", lhs, rhs), do: compare_result(compare(lhs, rhs), &(&1 == 0))
  defp binary("gt", lhs, rhs), do: compare_result(compare(lhs, rhs), &(&1 > 0))
  defp binary("gte", lhs, rhs), do: compare_result(compare(lhs, rhs), &(&1 >= 0))
  defp binary("lt", lhs, rhs), do: compare_result(compare(lhs, rhs), &(&1 < 0))
  defp binary("lte", lhs, rhs), do: compare_result(compare(lhs, rhs), &(&1 <= 0))
  defp binary("in", haystack, needle), do: eval_in(haystack, needle)
  defp binary("contains", haystack, needle), do: eval_in(haystack, needle)
  defp binary("match", text, pattern), do: eval_match(text, pattern)

  defp compare_result(nil, _fun), do: nil
  defp compare_result(cmp, fun), do: fun.(cmp)

  defp eval_in(haystack, needle) when is_list(haystack) do
    Enum.any?(haystack, &(compare(&1, needle) == 0))
  end

  defp eval_in(haystack, needle) when is_binary(haystack) do
    case string_convert(needle) do
      nil -> false
      needle_string -> String.contains?(haystack, needle_string)
    end
  end

  defp eval_in(haystack, needle) when is_map(haystack) do
    case string_convert(needle) do
      nil -> false
      needle_string -> Map.has_key?(haystack, needle_string)
    end
  end

  defp eval_in(_haystack, _needle), do: nil

  defp eval_match(text, pattern) do
    with text when is_binary(text) <- string_convert(text),
         pattern when is_binary(pattern) <- string_convert(pattern) do
      run_match(text, pattern)
    else
      _ -> nil
    end
  end

  defp run_match(text, pattern) do
    if String.length(pattern) > @max_regex_length do
      Logger.warning(
        "Regex pattern too long (#{String.length(pattern)}), rejecting: #{String.slice(pattern, 0, 100)}..."
      )

      nil
    else
      case Regex.compile(pattern) do
        {:ok, regex} ->
          task = Task.async(fn -> Regex.match?(regex, text) end)

          case Task.yield(task, @regex_timeout_ms) || Task.shutdown(task) do
            {:ok, result} ->
              result

            nil ->
              Logger.error(
                "Regex timeout (#{@regex_timeout_ms}ms): pattern=#{pattern}, text=#{String.slice(text, 0, 100)}"
              )

              nil
          end

        {:error, reason} ->
          Logger.error("Invalid regex pattern: #{pattern}, reason: #{inspect(reason)}")
          nil
      end
    end
  end

  @doc """
  Compare two values the way the JavaScript SDK's `Evaluator.compare` does.

  The right operand is converted to the left operand's type. Returns 0 when
  equal, 1 / -1 for an ordering, and nil when the values cannot be compared.
  Lists and maps only compare as equal (0) or not comparable (nil).
  """
  def compare(nil, nil), do: 0
  def compare(nil, _), do: nil
  def compare(_, nil), do: nil

  def compare(lhs, rhs) when is_number(lhs) do
    case number_convert(rhs) do
      nil -> nil
      rvalue -> order(lhs, rvalue)
    end
  end

  def compare(lhs, rhs) when is_binary(lhs) do
    case string_convert(rhs) do
      nil -> nil
      rvalue -> order(lhs, rvalue)
    end
  end

  def compare(lhs, rhs) when is_boolean(lhs) do
    rvalue = boolean_convert(rhs)

    cond do
      lhs == rvalue -> 0
      lhs -> 1
      true -> -1
    end
  end

  def compare(lhs, rhs) do
    if lhs == rhs, do: 0, else: nil
  end

  defp order(lhs, rhs) do
    cond do
      lhs == rhs -> 0
      lhs > rhs -> 1
      true -> -1
    end
  end

  @doc false
  def boolean_convert(x) when is_boolean(x), do: x
  def boolean_convert(x) when is_number(x), do: x != 0
  def boolean_convert(x) when is_binary(x), do: x not in ["false", "0", ""]
  def boolean_convert(x), do: x != nil

  @doc false
  def number_convert(x) when is_number(x), do: x
  def number_convert(true), do: 1
  def number_convert(false), do: 0
  def number_convert(x) when is_binary(x), do: parse_float(x)
  def number_convert(_), do: nil

  @doc false
  def string_convert(x) when is_binary(x), do: x
  def string_convert(x) when is_boolean(x), do: Atom.to_string(x)

  def string_convert(x) when is_number(x) do
    ABSmartly.Utils.number_to_fixed(x, 15)
    |> String.replace(~r/\.?0{0,15}$/, "", global: false)
  end

  def string_convert(_), do: nil

  # JS parseFloat: leading whitespace is skipped and the longest numeric
  # prefix is used; anything that is not a finite number gives nil.
  defp parse_float(s) do
    regex = ~r/^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?/

    whitespace =
      ~r/^[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]*/u

    [_, sign, int, frac, exp] =
      (Regex.run(regex, Regex.replace(whitespace, s, "")) ++ ["", "", "", ""]) |> Enum.take(5)

    if int == "" and frac == "" do
      nil
    else
      digits = fn d -> if d == "", do: "0", else: d end

      case Float.parse("#{sign}#{digits.(int)}.#{digits.(frac)}e#{digits.(exp)}") do
        {num, ""} -> num
        _ -> nil
      end
    end
  rescue
    ArgumentError -> nil
  end
end
