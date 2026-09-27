defmodule Xeito.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Xeito.RunRegistry},
        Xeito.Events,
        {Task.Supervisor, name: Xeito.EffectTasks},
        Xeito.Budget,
        Xeito.Tiers.Queue
      ] ++
        log_children() ++
        [
          {Registry, keys: :unique, name: Xeito.LogRegistry},
          {DynamicSupervisor, name: Xeito.WorkspaceLogs, strategy: :one_for_one},
          Xeito.RunSupervisor,
          {Registry, keys: :unique, name: Xeito.SessionRegistry},
          {DynamicSupervisor, name: Xeito.SessionSupervisor, strategy: :one_for_one},
          {DynamicSupervisor, name: Xeito.ApiConnections, strategy: :one_for_one}
        ] ++ api_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Xeito.Supervisor)
  end

  # The client API (Unix socket) runs in the daemon only: `mix xeito.daemon` or `config :xeito, api: true`.
  defp api_children do
    if Application.get_env(:xeito, :api, false), do: [Xeito.Api], else: []
  end

  # The default log is started unless disabled (tests start their own logs).
  defp log_children do
    if Application.get_env(:xeito, :start_log, true) do
      path = Application.get_env(:xeito, :log_path, ".xeito/log.sqlite")
      [{Xeito.Log, path: path, name: Xeito.Log}]
    else
      []
    end
  end
end
