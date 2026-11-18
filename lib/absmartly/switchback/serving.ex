defmodule ABSmartly.Switchback.Serving do
  @moduledoc false
  # Which unit serves a switchback experiment and under which cluster key.
  # Port of the Java SDK's internal.SwitchbackServing and
  # SwitchbackClusterKeys (java-sdk#15), themselves ports of the Collector's
  # ContextAPI.switchbackServing (R33, cluster-defined switchbacks):
  #
  # - The experiment's `switchbackClusters`, in declared order, list the
  #   linked unit types and, for each, the attribute path of its cluster value.
  # - No context unit of a linked type: the experiment does not apply (:absent).
  # - Otherwise each linked unit, in source order, reads the attribute at its
  #   source's path, normalised by `cluster_key/1`. The first unit yielding a
  #   value is the serving unit and the value is the cluster key; units
  #   yielding no value are skipped.
  # - :ineligible, under the first linked unit: no unit yields a value, two
  #   units yield different values, or an allow-list is set and lacks the key.
  # - :eligible otherwise.
  # - A missing, empty or unreadable cluster map takes the Collector's legacy
  #   path instead (`legacy/2`).

  alias ABSmartly.Switchback.AttributePath

  # `sources` is the experiment's parsed cluster map, `[{unit_type, path}]` in
  # declared order. `units` is the context's unit map; it has one uid per
  # type, so only the declared source order decides which unit serves.
  # `read` returns the raw attribute value a path reads, or nil.
  #
  # Returns `{status, unit_type, cluster_key}`; the unit type is nil only when
  # :absent, the cluster key is set only when :eligible.
  def resolve(sources, allowed_values, units, read) do
    {first, serving, key, disagree} =
      Enum.reduce(sources, {nil, nil, nil, false}, fn {type, path}, acc ->
        if Map.has_key?(units, type), do: read_source(acc, type, path, read), else: acc
      end)

    cond do
      first == nil -> {:absent, nil, nil}
      key == nil or disagree or not allowed?(allowed_values, key) -> {:ineligible, first, nil}
      true -> {:eligible, serving, key}
    end
  end

  defp read_source({first, serving, key, disagree}, type, path, read) do
    first = first || type

    case cluster_key(read.(path)) do
      nil -> {first, serving, key, disagree}
      value when key == nil -> {first, type, value, disagree}
      value -> {first, serving, key, disagree or value != key}
    end
  end

  # The Collector's compatibility path for a missing, empty or unreadable
  # cluster map: a unit of the experiment's declared unitType only identifies
  # an ineligible control (never an assignment or a cluster); without one the
  # experiment does not apply.
  def legacy(unit_type, units) do
    if is_binary(unit_type) and Map.has_key?(units, unit_type),
      do: {:ineligible, unit_type, nil},
      else: {:absent, nil, nil}
  end

  # A null or empty allow-list admits every value, as in the Collector.
  defp allowed?(allowed, _key) when allowed in [nil, []], do: true
  defp allowed?(allowed, key), do: key in allowed

  @doc """
  The cluster key an attribute value yields, or nil when it yields none
  (the Collector's `SwitchbackClusterKeys.normalize`): a non-empty string is
  the key as-is and an integer is its base-10 text. Nil, an empty string, a
  boolean, every float (`3.0` included), a map and a list yield no key. The
  key is never hashed.
  """
  def cluster_key(value) when is_binary(value) and value != "", do: value
  def cluster_key(value) when is_integer(value), do: Integer.to_string(value)
  def cluster_key(_value), do: nil

  # The parsed sources of a `switchbackClusters` value (an ordered list of
  # `{unit_type, path}` pairs, see ExperimentData), or nil for a missing,
  # empty or unreadable map: the legacy path.
  def sources(clusters) when is_list(clusters) and clusters != [] do
    Enum.reduce_while(clusters, [], fn
      {type, path}, acc when is_binary(type) ->
        case AttributePath.parse_supported(path) do
          nil -> {:halt, nil}
          parsed -> {:cont, [{type, parsed} | acc]}
        end

      _, _acc ->
        {:halt, nil}
    end)
    |> case do
      nil -> nil
      sources -> Enum.reverse(sources)
    end
  end

  def sources(_clusters), do: nil
end
