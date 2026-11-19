defmodule ABSmartly.Switchback.AttributePath do
  @moduledoc false
  # A switchback cluster attribute path, resolved like the Collector's
  # SwitchbackAttributePath (port of the Java SDK's internal class,
  # java-sdk#15): "/" separates segments, a segment wrapped in ' or " is a
  # literal key, and an unquoted segment that Guava Ints.tryParse accepts
  # (ASCII digits, optional leading '-', within int32) indexes a list and
  # nothing else. Every other segment reads a map key. A path is malformed,
  # and its experiment unservable, when a quote is left unterminated or any
  # segment, quoted or not, contains a '.' (nesting is written with '/').
  #
  # A parsed path is a list of segments, `{:key, key}` or `{:index, key, n}`;
  # an index segment keeps its text so a map is never read by it.

  @int32_min -2_147_483_648
  @int32_max 2_147_483_647
  @max_depth 64

  # Returns the parsed path, or nil for an unsupported path: malformed (see
  # above), empty, or an index that is negative, first, last, or directly
  # after another index. Analysis cannot read those.
  def parse_supported(path) when is_binary(path) do
    with false <- String.contains?(path, "."),
         {:ok, [_ | _] = segments} <- parse(path, []),
         true <- supported_indices?(segments, nil) do
      segments
    else
      _ -> nil
    end
  end

  def parse_supported(_path), do: nil

  def root_key([{:key, key} | _]), do: key

  # Resolves the path below its root in an attribute value, read as the
  # Collector reads it: the value's JSON encoding, decoded by Jason into maps,
  # lists, strings, booleans, integers and floats. Nil when the value has no
  # JSON encoding (a tuple, a pid, a non-UTF-8 binary, ...) or, as in the Java
  # SDK, nests maps and lists deeper than 64 levels.
  def resolve_attribute([_root | rest], value) do
    if within_depth?(value, 0), do: walk(rest, decoded(value))
  rescue
    # An improper list.
    _ -> nil
  end

  def resolve(segments, attributes), do: walk(segments, attributes)

  defp decoded(value) when is_binary(value) do
    if String.valid?(value), do: value
  end

  # Each of these decodes back to an equal value of the same type.
  defp decoded(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: value

  defp decoded(value) do
    with {:ok, json} <- Jason.encode(value),
         {:ok, decoded} <- Jason.decode(json) do
      decoded
    else
      _ -> nil
    end
  end

  defp within_depth?(value, depth)
       when is_list(value) or (is_map(value) and not is_struct(value)) do
    depth < @max_depth and
      Enum.all?(
        if(is_map(value), do: Map.values(value), else: value),
        &within_depth?(&1, depth + 1)
      )
  end

  defp within_depth?(_value, _depth), do: true

  defp walk(_segments, nil), do: nil
  defp walk([], value), do: value

  defp walk([{:index, _key, index} | rest], list) when is_list(list),
    do: walk(rest, Enum.at(list, index))

  defp walk([{:index, _key, _index} | _rest], _value), do: nil

  defp walk([{:key, key} | rest], %{} = map) when not is_struct(map),
    do: walk(rest, Map.get(map, key))

  defp walk([{:key, _key} | _rest], _value), do: nil

  defp parse("", acc), do: {:ok, Enum.reverse(acc)}
  defp parse("/" <> rest, acc), do: parse(rest, acc)

  defp parse(<<quote, rest::binary>>, acc) when quote in [?', ?"] do
    # As in the Collector and the Java SDK, parsing continues right after the
    # closing quote, so text after it (`"city"junk`) is the next segment.
    case :binary.split(rest, <<quote>>) do
      [key, rest] -> parse(rest, [{:key, key} | acc])
      [_unterminated] -> :error
    end
  end

  defp parse(path, acc) do
    {key, rest} =
      case :binary.split(path, "/") do
        [key, rest] -> {key, rest}
        [key] -> {key, ""}
      end

    segment = if index = try_parse_int(key), do: {:index, key, index}, else: {:key, key}
    parse(rest, [segment | acc])
  end

  defp supported_indices?([], _previous), do: true

  defp supported_indices?([{:index, _, index} | rest], previous) do
    index >= 0 and match?({:key, _}, previous) and rest != [] and
      supported_indices?(rest, {:index, nil, index})
  end

  defp supported_indices?([segment | rest], _previous), do: supported_indices?(rest, segment)

  # Guava Ints.tryParse: an optional '-', then one or more ASCII digits,
  # within int32; otherwise nil. "+1" and non-ASCII digits are not numbers;
  # "-0" is 0.
  @doc false
  def try_parse_int("-" <> digits), do: digits |> ascii_digits() |> negate() |> in_int32()
  def try_parse_int(digits), do: digits |> ascii_digits() |> in_int32()

  defp ascii_digits(""), do: nil

  defp ascii_digits(digits) do
    if digits =~ ~r/\A[0-9]+\z/, do: String.to_integer(digits)
  end

  defp negate(nil), do: nil
  defp negate(n), do: -n

  defp in_int32(n) when is_integer(n) and n >= @int32_min and n <= @int32_max, do: n
  defp in_int32(_), do: nil
end
