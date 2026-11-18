defmodule ABSmartly.Switchback.JsonTest do
  use ExUnit.Case, async: true

  alias ABSmartly.Switchback.Json

  defp clusters_of(body) do
    {:ok, %{"experiments" => [experiment]}} = Json.decode(body)
    experiment["switchbackClusters"]
  end

  test "keeps the declared order, also with an escaped key spelling" do
    for key <- ["switchbackClusters", "switchback\\u0043lusters"] do
      body = ~s({"experiments":[{"#{key}":{"user_id":"a","session_id":"b","device_id":"c"}}]})

      assert clusters_of(body) == %Jason.OrderedObject{
               values: [{"user_id", "a"}, {"session_id", "b"}, {"device_id", "c"}]
             },
             key
    end
  end

  test "a repeated key keeps its first position and its last value, as Jackson does" do
    body = ~s({"experiments":[{"switchbackClusters":{"b":"1","a":"2","b":"3"}}]})
    assert clusters_of(body) == %Jason.OrderedObject{values: [{"b", "3"}, {"a", "2"}]}
  end

  test "everything else decodes exactly as Jason.decode/1" do
    body =
      ~s({"experiments":[{"id":1,"switchbackClusters":{"z":"p","a":"q"},"variants":[{"config":"{}","x":{"k":[1,{"m":2}]}}]}],"holdouts":[{"id":2}],"u":"\\u00e9"})

    {:ok, plain} = Jason.decode(body)
    {:ok, decoded} = Json.decode(body)

    assert update_in(
             decoded,
             ["experiments", Access.at(0)],
             &Map.delete(&1, "switchbackClusters")
           ) ==
             update_in(
               plain,
               ["experiments", Access.at(0)],
               &Map.delete(&1, "switchbackClusters")
             )
  end

  test "a body without a multi-entry switchbackClusters is decoded once" do
    for body <- [
          ~s({"experiments":[{"id":1,"name":"\\u00e9"}]}),
          ~s({"experiments":[{"switchbackClusters":{"a":"b"}}]})
        ] do
      assert Json.decode(body) == Jason.decode(body)
    end
  end

  test "invalid JSON is an error, as with Jason.decode/1" do
    assert {:error, %Jason.DecodeError{}} = Json.decode("{")
  end
end
