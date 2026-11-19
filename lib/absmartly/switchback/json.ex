defmodule ABSmartly.Switchback.Json do
  @moduledoc """
  Decodes context JSON with each experiment's `switchbackClusters` kept in
  its JSON order.

  The order of `switchbackClusters` decides which unit serves a switchback
  experiment, and `Jason.decode/1` gives an unordered map. `decode/1` keeps
  the `switchbackClusters` of every object in an `experiments` list as a
  `Jason.OrderedObject` (with string values; a repeated key keeps its first
  position and last value, as Jackson does). Everything else decodes exactly
  as `Jason.decode/1` decodes it, including a repeated key, which keeps its
  first value, and customer configuration such as an object-valued variant
  `config`, which stays a plain map even when it contains a key named
  `switchbackClusters`. A body without an experiment `switchbackClusters` is
  decoded once, by `Jason.decode/1`.

  The `experiments` list may sit at any depth, so a body that wraps context
  data (`{"data": {"experiments": [...]}}`) keeps its order too.

  Use it when you fetch context data yourself and pass it to
  `ABSmartly.Types.ContextData.from_map/1`.
  """

  @doc """
  Like `Jason.decode/1`, but keeps every experiment's `switchbackClusters`
  ordered.
  """
  def decode(body) when is_binary(body) do
    with {:ok, decoded} <- decode_plain(body) do
      if clusters_present?(decoded) do
        with {:ok, ordered} <- Jason.decode(body, objects: :ordered_objects),
             do: {:ok, normalize(ordered)}
      else
        {:ok, plain(decoded)}
      end
    end
  end

  defp plain({:plain, decoded}), do: decoded
  defp plain(decoded), do: decoded

  # Tags the result {:plain, decoded} when the body has no switchbackClusters
  # key, so the walk is skipped. A body with an escape may spell the key with
  # escapes, so its keys are checked as they are decoded, in the same pass.
  defp decode_plain(body) do
    if :binary.match(body, "switchbackClusters") != :nomatch do
      Jason.decode(body)
    else
      key = {__MODULE__, :seen}
      Process.delete(key)

      result =
        Jason.decode(body,
          keys: fn
            "switchbackClusters" = k ->
              Process.put(key, true)
              k

            k ->
              k
          end
        )

      seen = Process.delete(key)

      with {:ok, decoded} <- result,
           do: {:ok, if(seen, do: decoded, else: {:plain, decoded})}
    end
  end

  # Whether any experiment carries a switchbackClusters object. Every such
  # object takes the ordered decode, whatever its size, so a repeated member
  # resolves the same way whether or not another experiment has clusters.
  defp clusters_present?({:plain, _decoded}), do: false

  defp clusters_present?(%{"experiments" => experiments} = map) when is_list(experiments) do
    Enum.any?(experiments, &match?(%{"switchbackClusters" => %{}}, &1)) or
      Enum.any?(experiments, &(match?(%{}, &1) and clusters_present?(Map.delete(&1, "variants")))) or
      Enum.any?(Map.delete(map, "experiments"), fn {_key, value} -> clusters_present?(value) end)
  end

  defp clusters_present?(%{} = map),
    do: Enum.any?(map, fn {_key, value} -> clusters_present?(value) end)

  defp clusters_present?(list) when is_list(list), do: Enum.any?(list, &clusters_present?/1)
  defp clusters_present?(_value), do: false

  @doc """
  Turns every `Jason.OrderedObject` in a value decoded with
  `objects: :ordered_objects` into a map, except the `switchbackClusters` of
  each object in an `experiments` list. A repeated key keeps its first value,
  as `Jason.decode/1` does, except inside `switchbackClusters` (see
  `decode/1`).
  """
  def normalize(value), do: normalize(value, :other)

  defp normalize(%Jason.OrderedObject{values: values}, context) do
    # Reversed so that, as in `Jason.decode/1`, the first of a repeated key
    # wins (Map.new/2 keeps the last).
    values
    |> Enum.reverse()
    |> Map.new(fn
      {"switchbackClusters", %Jason.OrderedObject{values: clusters}}
      when context == :experiment ->
        {"switchbackClusters", %Jason.OrderedObject{values: dedup(clusters)}}

      {"experiments", experiments} when is_list(experiments) and context != :data ->
        {"experiments", Enum.map(experiments, &normalize(&1, :experiment))}

      # Variant configuration is customer data: decoded as plain maps, like
      # Jason.decode/1, whatever keys it holds.
      {"variants", variants} when context == :experiment ->
        {"variants", normalize(variants, :data)}

      {key, value} ->
        {key, normalize(value, if(context == :data, do: :data, else: :other))}
    end)
  end

  defp normalize(list, :data) when is_list(list), do: Enum.map(list, &normalize(&1, :data))
  defp normalize(list, _context) when is_list(list), do: Enum.map(list, &normalize(&1, :other))
  defp normalize(other, _context), do: other

  # A repeated key keeps its first position and its last value, as a
  # LinkedHashMap (the Java SDK's Jackson decode) does.
  defp dedup(pairs) do
    last = Map.new(pairs)

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&{&1, normalize(Map.fetch!(last, &1))})
  end
end
