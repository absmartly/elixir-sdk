defmodule ABSmartly.Semver do
  @moduledoc """
  Semantic version comparison used by the `semver_*` JSON expression operators.

  Mirrors the JavaScript SDK's `versionCompare` (src/jsonexpr/evaluator.ts): a
  leading `v`/`V` and any `+build` metadata are ignored, the core is split on
  `.` into any number of parts (missing parts count as `0`), and the
  pre-release is everything after the first `-`. Numeric identifiers compare
  numerically (leading zeros ignored) and sort before alphanumeric ones; a
  version without a pre-release is greater than the same version with one.

  Parsing is deliberately as permissive as the JavaScript and Java SDKs', so
  every SDK orders the same inputs the same way: a non-numeric core part (as
  in `"1.x"` or `"garbage"`) is compared as an alphanumeric identifier, an
  empty part (as in `"1..0"`) is an identifier of its own, and an empty
  pre-release or build (`"1.0.0-"`, `"1.0.0+"`) counts as absent. Only an
  empty version core gives `nil`.
  """

  @numeric ~r/^\d+$/

  @doc """
  Compare two versions. Returns -1, 0 or 1, or nil when either is not a
  string or has an empty version core once a leading `v`/`V` and any `+build`
  metadata are removed (`""`, `"v"`, `"+build"`, `"-beta"`).

  ## Examples

      iex> ABSmartly.Semver.compare("1.10.0", "1.9.0")
      1

      iex> ABSmartly.Semver.compare("v1.0.0-alpha", "1.0.0")
      -1

      iex> ABSmartly.Semver.compare("", "1.0.0")
      nil
  """
  def compare(lhs, rhs) when is_binary(lhs) and is_binary(rhs) and lhs != "" and rhs != "" do
    with {lhs_parts, lhs_pre} <- parse(lhs),
         {rhs_parts, rhs_pre} <- parse(rhs) do
      case compare_core(lhs_parts, rhs_parts) do
        0 -> compare_pre_release(lhs_pre, rhs_pre)
        result -> result
      end
    end
  end

  def compare(_lhs, _rhs), do: nil

  defp parse(version) do
    version =
      case version do
        "v" <> rest -> rest
        "V" <> rest -> rest
        other -> other
      end

    [version | _build] = String.split(version, "+", parts: 2)

    case String.split(version, "-", parts: 2) do
      [""] -> nil
      ["" | _] -> nil
      [core] -> {String.split(core, "."), ""}
      [core, pre_release] -> {String.split(core, "."), pre_release}
    end
  end

  defp compare_core([], []), do: 0

  defp compare_core(lhs, rhs) do
    {l, lhs_rest} = pop(lhs)
    {r, rhs_rest} = pop(rhs)

    case compare_identifiers(l, r) do
      0 -> compare_core(lhs_rest, rhs_rest)
      result -> result
    end
  end

  defp pop([]), do: {"0", []}
  defp pop([head | rest]), do: {head, rest}

  defp compare_pre_release("", ""), do: 0
  defp compare_pre_release("", _), do: 1
  defp compare_pre_release(_, ""), do: -1

  defp compare_pre_release(lhs, rhs),
    do: compare_pre_parts(String.split(lhs, "."), String.split(rhs, "."))

  defp compare_pre_parts([], []), do: 0
  defp compare_pre_parts([], _), do: -1
  defp compare_pre_parts(_, []), do: 1

  defp compare_pre_parts([l | lhs_rest], [r | rhs_rest]) do
    case compare_identifiers(l, r) do
      0 -> compare_pre_parts(lhs_rest, rhs_rest)
      result -> result
    end
  end

  defp compare_identifiers(a, b) do
    case {a =~ @numeric, b =~ @numeric} do
      {true, true} ->
        a = strip_leading_zeros(a)
        b = strip_leading_zeros(b)

        cond do
          byte_size(a) != byte_size(b) -> order(byte_size(a), byte_size(b))
          true -> order(a, b)
        end

      {true, false} ->
        -1

      {false, true} ->
        1

      {false, false} ->
        order(a, b)
    end
  end

  defp strip_leading_zeros(s) do
    case String.trim_leading(s, "0") do
      "" -> "0"
      stripped -> stripped
    end
  end

  defp order(a, b) when a > b, do: 1
  defp order(a, b) when a < b, do: -1
  defp order(_, _), do: 0
end
