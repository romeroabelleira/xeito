defmodule Xeito.Case do
  @moduledoc "Test helpers: a private log per test and polling assertions."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Xeito.Case
    end
  end

  @doc "Starts a log in a fresh temporary directory and returns its pid."
  def start_log!(name \\ "log") do
    dir = Path.join(System.tmp_dir!(), "xeito-test-#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)

    ExUnit.Callbacks.start_supervised!({Xeito.Log, path: Path.join(dir, "#{name}.sqlite")},
      id: make_ref()
    )
  end

  @doc "A unique run id."
  def run_id, do: "test-run-#{System.unique_integer([:positive])}"

  @doc "Polls `fun` until it returns a truthy value (or fails after `timeout` ms)."
  def eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
        Process.sleep(10)
        poll(fun, deadline)

      value ->
        value
    end
  end

  @doc "A fake runner whose bash results come from `bash_results` (in order) and decisions from `decide`."
  def scripted_runner(bash_results, decide \\ fn _ -> :abstain end) do
    {:ok, agent} = Agent.start_link(fn -> bash_results end)

    fun = fn
      %Xeito.Effect{kind: :bash} ->
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {%{exit_status: 0, output: "default"}, []}
        end)

      %Xeito.Effect{kind: :decide} = effect ->
        %{value: decide.(effect)}
    end

    {Xeito.Effects.Fake, fun: fun}
  end

  @doc "Waits until the run process is gone."
  def await_exit(run_id) do
    eventually(fn -> Xeito.Run.whereis(run_id) == nil end)
  end
end
