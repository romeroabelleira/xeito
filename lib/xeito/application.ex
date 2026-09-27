defmodule Xeito.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Xeito.RunRegistry},
        {Task.Supervisor, name: Xeito.EffectTasks},
        Xeito.Budget,
        Xeito.Tiers.Queue
      ] ++ log_children() ++ [Xeito.RunSupervisor]

    Supervisor.start_link(children, strategy: :one_for_one, name: Xeito.Supervisor)
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
