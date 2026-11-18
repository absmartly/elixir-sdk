defmodule ABSmartly.Switchback.Json do
  @moduledoc """
  Decodes context JSON with each experiment's `switchbackClusters` kept in
  its JSON order.

  The order of `switchbackClusters` decides which unit serves a switchback
  experiment, and `Jason.decode/1` gives an unordered map. `decode/1` decodes
  with `objects: :ordered_objects` and turns every object back into a map,
  except each `switchbackClusters` value, which stays a `Jason.OrderedObject`
  (its values are plain). A body that never mentions `switchbackClusters`
  takes `Jason.decode/1`, so it costs nothing.

  Use it when you fetch context data yourself and pass it to
  `ABSmartly.Types.ContextData.from_map/1`.
  """

  @doc """
  Like `Jason.decode/1`, but keeps every `switchbackClusters` object ordered.
  """
  def decode(body) when is_binary(body) do
    if :binary.match(body, ["switchbackClusters", "\\u"]) == :nomatch do
      Jason.decode(body)
    else
      with {:ok, decoded} <- Jason.decode(body, objects: :ordered_objects),
           do: {:ok, normalize(decoded)}
    end
  end

  @doc """
  Turns every `Jason.OrderedObject` in a value decoded with
  `objects: :ordered_objects` into a map, except the value of each
  `switchbackClusters` key.
  """
  def normalize(%Jason.OrderedObject{values: values}) do
    Map.new(values, fn
      {"switchbackClusters", %Jason.OrderedObject{values: clusters}} ->
        {"switchbackClusters",
         %Jason.OrderedObject{values: Enum.map(clusters, fn {k, v} -> {k, normalize(v)} end)}}

      {key, value} ->
        {key, normalize(value)}
    end)
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(other), do: other
end
