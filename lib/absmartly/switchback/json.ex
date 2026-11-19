defmodule ABSmartly.Switchback.Json do
  @moduledoc """
  Decodes context JSON with each experiment's `switchbackClusters` kept in
  its JSON order.

  The order of `switchbackClusters` decides which unit serves a switchback
  experiment, and `Jason.decode/1` gives an unordered map. `decode/1` keeps
  the `switchbackClusters` of each experiment in the context data's
  `experiments` list as a `Jason.OrderedObject` (with string values; a
  repeated key keeps its first position and last value, as Jackson does).
  The context data is the body itself, or its `data` member for a body that
  wraps it (`{"data": {"experiments": [...]}}`). Everything else decodes
  exactly as `Jason.decode/1` decodes it, including a repeated key, which
  keeps its first value, and every other field of an experiment (its
  variants, applications and their metadata), whatever keys they hold. A
  body without an experiment `switchbackClusters` is decoded once, by
  `Jason.decode/1`.

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

  # Whether an experiment of the context data carries a switchbackClusters
  # object. Every such object takes the ordered decode, whatever its size, so
  # a repeated member resolves the same way whether or not another experiment
  # has clusters.
  defp clusters_present?({:plain, _decoded}), do: false

  defp clusters_present?(%{} = body) do
    Enum.any?([body, body["data"]], fn
      %{"experiments" => experiments} when is_list(experiments) ->
        Enum.any?(experiments, &match?(%{"switchbackClusters" => %{}}, &1))

      _ ->
        false
    end)
  end

  defp clusters_present?(_decoded), do: false

  @doc """
  Turns every `Jason.OrderedObject` in a value decoded with
  `objects: :ordered_objects` into a map, except the `switchbackClusters` of
  each experiment in the context data (see `decode/1`). A repeated key keeps
  its first value, as `Jason.decode/1` does, except inside
  `switchbackClusters`.
  """
  def normalize(%Jason.OrderedObject{values: values}) do
    plain_object(values, fn
      {key, %Jason.OrderedObject{values: members}} when key == "data" ->
        context_data(members)

      {"experiments", experiments} when is_list(experiments) ->
        Enum.map(experiments, &experiment/1)

      {_key, value} ->
        plain_json(value)
    end)
  end

  def normalize(value), do: plain_json(value)

  defp context_data(members) do
    plain_object(members, fn
      {"experiments", experiments} when is_list(experiments) ->
        Enum.map(experiments, &experiment/1)

      {_key, value} ->
        plain_json(value)
    end)
  end

  defp experiment(%Jason.OrderedObject{values: fields}) do
    plain_object(fields, fn
      {"switchbackClusters", %Jason.OrderedObject{values: clusters}} ->
        %Jason.OrderedObject{values: dedup(clusters)}

      {_key, value} ->
        plain_json(value)
    end)
  end

  defp experiment(other), do: plain_json(other)

  # A map built from ordered pairs, valued by `value/1`. Reversed so that, as
  # in `Jason.decode/1`, the first of a repeated key wins (Map.new/2 keeps
  # the last).
  defp plain_object(pairs, value) do
    pairs |> Enum.reverse() |> Map.new(fn {key, _} = pair -> {key, value.(pair)} end)
  end

  defp plain_json(%Jason.OrderedObject{values: values}),
    do: plain_object(values, fn {_key, value} -> plain_json(value) end)

  defp plain_json(list) when is_list(list), do: Enum.map(list, &plain_json/1)
  defp plain_json(other), do: other

  # A repeated key keeps its first position and its last value, as a
  # LinkedHashMap (the Java SDK's Jackson decode) does.
  defp dedup(pairs) do
    last = Map.new(pairs)

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&{&1, plain_json(Map.fetch!(last, &1))})
  end
end
