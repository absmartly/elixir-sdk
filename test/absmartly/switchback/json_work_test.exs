defmodule ABSmartly.Switchback.JsonWorkTest do
  use ExUnit.Case, async: false

  alias ABSmartly.Switchback.Json

  test "ordinary payloads do not recursively walk decoded objects" do
    Code.ensure_loaded!(Json)

    body =
      Jason.encode!(%{
        "experiments" => [%{"id" => 1, "variants" => [%{"config" => %{"nested" => [1, 2, 3]}}]}],
        "future" => %{"deep" => [%{"object" => true}]}
      })

    assert_walk_calls(body)

    assert_walk_calls(
      ~s({"experiments":[{"name":"\\u00e9","variants":[{"config":{"nested":[1,2,3]}}]}]})
    )
  end

  defp assert_walk_calls(body) do
    parent = self()

    worker =
      spawn(fn ->
        receive do
          {:decode, text} -> send(parent, {:decoded, Json.decode(text)})
        end
      end)

    :erlang.trace(worker, true, [:call, {:tracer, self()}])
    :erlang.trace_pattern({Json, :clusters_present?, 1}, true, [:local])

    try do
      send(worker, {:decode, body})
      assert_receive {:decoded, {:ok, _}}
    after
      :erlang.trace_pattern({Json, :clusters_present?, 1}, false, [:local])
    end

    calls = collect_ordered_walk_calls(0)
    # The tagged plain result takes the single top-level clause; removing the
    # fast-path skip makes this recurse through every decoded object.
    assert calls == 1
  end

  defp collect_ordered_walk_calls(count) do
    receive do
      {:trace, _, :call, {Json, :clusters_present?, [_]}} ->
        collect_ordered_walk_calls(count + 1)
    after
      0 -> count
    end
  end
end
