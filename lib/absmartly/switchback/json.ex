defmodule ABSmartly.Switchback.Json do
  @moduledoc """
  Decodes context JSON with each experiment's `switchbackClusters` kept in
  its JSON order.

  The order of `switchbackClusters` decides which unit serves a switchback
  experiment, and `Jason.decode/1` gives an unordered map. `decode/1` decodes
  with `objects: :ordered_objects` and turns every object back into a map,
  except each `switchbackClusters` value, which stays a `Jason.OrderedObject`
  (its values are plain; a repeated key keeps its first position and last
  value, as Jackson does). A body without a `switchbackClusters` of two or
  more entries is decoded once by `Jason.decode/1`, as before.

  Use it when you fetch context data yourself and pass it to
  `ABSmartly.Types.ContextData.from_map/1`.
  """

  @doc """
  Like `Jason.decode/1`, but keeps every `switchbackClusters` object ordered.
  """
  def decode(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body) do
      # The key may be written with escapes, so only a body with neither
      # the key nor an escape skips the walk.
      if :binary.match(body, ["switchbackClusters", "\\u"]) != :nomatch and
           ordered_clusters_needed?(decoded) do
        with {:ok, ordered} <- Jason.decode(body, objects: :ordered_objects),
             do: {:ok, normalize(ordered)}
      else
        {:ok, decoded}
      end
    end
  end

  # Only a `switchbackClusters` object with two or more entries has an order
  # to keep, so a body without one is decoded once, as before.
  defp ordered_clusters_needed?(%{"switchbackClusters" => %{} = clusters})
       when map_size(clusters) > 1,
       do: true

  defp ordered_clusters_needed?(%{} = map),
    do: Enum.any?(map, fn {_key, value} -> ordered_clusters_needed?(value) end)

  defp ordered_clusters_needed?(list) when is_list(list),
    do: Enum.any?(list, &ordered_clusters_needed?/1)

  defp ordered_clusters_needed?(_value), do: false

  @doc """
  Turns every `Jason.OrderedObject` in a value decoded with
  `objects: :ordered_objects` into a map, except the value of each
  `switchbackClusters` key.
  """
  def normalize(%Jason.OrderedObject{values: values}) do
    Map.new(values, fn
      {"switchbackClusters", %Jason.OrderedObject{values: clusters}} ->
        {"switchbackClusters", %Jason.OrderedObject{values: dedup(clusters)}}

      {key, value} ->
        {key, normalize(value)}
    end)
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(other), do: other

  # A repeated key keeps its first position and its last value, as a
  # LinkedHashMap (the Java SDK's Jackson decode) does.
  defp dedup(pairs) do
    last = Map.new(pairs, fn {k, v} -> {k, v} end)

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&{&1, normalize(Map.fetch!(last, &1))})
  end
end
