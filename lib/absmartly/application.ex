defmodule ABSmartly.Application do
  @moduledoc """
  Application supervisor for ABSmartly SDK.

  Provides supervision tree for fault tolerance and recovery.
  Fixes CRITICAL-02: Unsupervised GenServer.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Context supervisor will be started on demand
      {DynamicSupervisor, name: ABSmartly.ContextSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: ABSmartly.Supervisor]

    Logger.info("Starting ABSmartly.Application")
    Supervisor.start_link(children, opts)
  end
end
