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

  test "a repeated key outside switchbackClusters keeps its first value, as Jason.decode/1 does" do
    body =
      ~s({"experiments":[{"name":"exp_unit","fullOnVariant":0,"fullOnVariant":2,"x":{"k":1,"k":3}},) <>
        ~s({"name":"exp_sb","switchbackClusters":{"a":"p","b":"q"}}]})

    {:ok, plain} = Jason.decode(body)
    {:ok, decoded} = Json.decode(body)
    [unit, _sb] = decoded["experiments"]
    assert {unit["fullOnVariant"], unit["x"]} == {0, %{"k" => 1}}
    assert unit == hd(plain["experiments"])
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

  test "a body without an experiment switchbackClusters decodes as Jason.decode/1" do
    for body <- [
          ~s({"experiments":[{"id":1,"name":"\\u00e9"}]}),
          ~s({"experiments":[{"id":1,"variants":[{"config":{"switchbackClusters":{"z":"1","a":"2"}}}]}]}),
          ~s({"switchbackClusters":{"z":"1","a":"2"}})
        ] do
      assert Json.decode(body) == Jason.decode(body), body
    end
  end

  test "an object-valued variant config named switchbackClusters stays a plain map" do
    body =
      ~s({"experiments":[{"switchbackClusters":{"u":"p","s":"q"},) <>
        ~s("variants":[{"config":{"switchbackClusters":{"z":"1","z":"2","a":"3"}}}]}]})

    {:ok, %{"experiments" => [experiment]}} = Json.decode(body)

    assert experiment["switchbackClusters"] == %Jason.OrderedObject{
             values: [{"u", "p"}, {"s", "q"}]
           }

    assert hd(experiment["variants"])["config"] == %{
             "switchbackClusters" => %{"z" => "1", "a" => "3"}
           }
  end

  # A repeated cluster member resolves the same way whether or not another
  # experiment has a multi-entry cluster map.
  test "a repeated cluster member does not depend on neighbouring experiments" do
    alone = ~s({"experiments":[{"switchbackClusters":{"store_id":"old","store_id":"new"}}]})

    with_neighbour =
      ~s({"experiments":[{"switchbackClusters":{"store_id":"old","store_id":"new"}},) <>
        ~s({"switchbackClusters":{"u":"p","s":"q"}}]})

    expected = %Jason.OrderedObject{values: [{"store_id", "new"}]}
    assert clusters_of(alone) == expected
    {:ok, %{"experiments" => [first, _]}} = Json.decode(with_neighbour)
    assert first["switchbackClusters"] == expected
  end

  test "a wrapped context payload keeps its cluster order" do
    body = ~s({"data":{"experiments":[{"switchbackClusters":{"z":"1","a":"2"}}]}})
    {:ok, %{"data" => %{"experiments" => [experiment]}}} = Json.decode(body)

    assert experiment["switchbackClusters"] == %Jason.OrderedObject{
             values: [{"z", "1"}, {"a", "2"}]
           }
  end

  # A wrapped payload's data member is the context data, so its experiments
  # keep their order next to a root experiments list without clusters.
  test "a wrapped payload keeps its order next to a root experiments list" do
    body =
      ~s({"experiments":[{"id":1}],"data":{"experiments":[{"switchbackClusters":{"z":"1","a":"2"}}]}})

    {:ok, %{"data" => %{"experiments" => [experiment]}}} = Json.decode(body)

    assert experiment["switchbackClusters"] == %Jason.OrderedObject{
             values: [{"z", "1"}, {"a", "2"}]
           }
  end

  test "an experiments list inside a variant config stays a plain map" do
    nested = ~s({"experiments":[{"switchbackClusters":{"z":"1","a":"2"}}]})

    for clusters <- ["", ~s("switchbackClusters":{"u":"p","s":"q"},)] do
      body = ~s({"experiments":[{#{clusters}"variants":[{"config":#{nested}}]}]})
      {:ok, %{"experiments" => [experiment]}} = Json.decode(body)
      assert hd(experiment["variants"])["config"] == Jason.decode!(nested), body
    end
  end

  # Only the context data (the body, or its data member) is a context
  # payload: an experiments list anywhere else in an experiment, such as
  # application metadata or an unknown field, is customer data.
  test "an experiments list inside an experiment's other fields stays plain" do
    nested = ~s({"experiments":[{"switchbackClusters":{"z":"1","a":"2"}}]})

    for clusters <- ["", ~s("switchbackClusters":{"u":"p","s":"q"},)] do
      body =
        ~s({"experiments":[{#{clusters}"id":1,"extra":#{nested},) <>
          ~s("applications":[{"name":"web","metadata":#{nested}}]}]})

      {:ok, %{"experiments" => [experiment]}} = Json.decode(body)
      assert experiment["extra"] == Jason.decode!(nested), body
      assert hd(experiment["applications"])["metadata"] == Jason.decode!(nested), body
    end
  end

  test "invalid JSON is an error, as with Jason.decode/1" do
    assert {:error, %Jason.DecodeError{}} = Json.decode("{")
  end
end
