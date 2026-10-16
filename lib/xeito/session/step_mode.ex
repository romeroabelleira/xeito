defmodule Xeito.Session.StepMode do
  @moduledoc """
  Step mode and breakpoints for a session's runs (`/step`, `/continue`, `/next`, `/decide`, `/break`).

  The settings are the session state's `debug` (`%{step: boolean, breakpoints: list}`); a change
  applies to every live run at once and to runs started later, and is confirmed with a notice.
  `track/3` keeps `live` (the session's runs, without its internal escalation and intent runs)
  and `paused` (the run waiting for a step) up to date from the runs' events. User input never
  creates atoms: decision values and state names must already exist.
  """

  alias Xeito.Run
  alias Xeito.Session
  alias Xeito.Session.Notify

  @doc "Sets the step-mode settings, applies them to the live runs, and emits a notice describing them."
  @spec set_debug(%{step: boolean(), breakpoints: list()}, Session.state()) :: Session.state()
  def set_debug(debug, s) do
    Enum.each(s.live, &debug_run(&1, debug))
    Notify.notice(%{s | debug: debug}, debug_text(debug))
  end

  defp debug_run(run, debug) do
    Run.debug(run, debug)
  catch
    :exit, _ -> :ok
  end

  defp debug_text(%{step: step, breakpoints: bps}) do
    "step mode #{if step, do: "on", else: "off"}" <>
      if(bps == [], do: "", else: " · breakpoints: " <> Enum.map_join(bps, ", ", &inspect/1))
  end

  @doc "Releases the paused run: one step (`:next`) or with a decision value typed by the user (`{:decide, text}`)."
  @spec step(:next | {:decide, String.t()}, Session.state()) :: Session.state()
  def step(_how, %{paused: nil} = s), do: Notify.error(s, "no run is paused")

  def step({:decide, value}, s) do
    case existing_atom(value) do
      {:ok, atom} -> release({:decide, atom}, s)
      :error -> Notify.error(s, "cannot step: invalid_value")
    end
  end

  def step(:next, s), do: release(:next, s)

  defp release(how, s) do
    case Run.step(s.paused, how) do
      :ok -> %{s | paused: nil}
      {:error, reason} -> Notify.error(s, "cannot step: #{reason}")
    end
  end

  defp existing_atom(text) do
    {:ok, String.to_existing_atom(text)}
  rescue
    ArgumentError -> :error
  end

  @doc "Adds the breakpoint `spec` (see `parse_breakpoint/1`), or emits an error listing the forms."
  @spec add_breakpoint(String.t(), Session.state()) :: Session.state()
  def add_breakpoint(spec, s) do
    case parse_breakpoint(spec) do
      {:ok, bp} -> set_debug(%{s.debug | breakpoints: Enum.uniq(s.debug.breakpoints ++ [bp])}, s)
      :error -> Notify.error(s, "breakpoints: state:<name>, decision:<Type>, conf<0.6, clear")
    end
  end

  @doc "A breakpoint from its spec: `state:<name>`, `decision:<type>` or `conf<<number>`."
  @spec parse_breakpoint(String.t()) ::
          {:ok, {:state, atom()} | {:decision, module()} | {:confidence_below, float()}} | :error
  def parse_breakpoint("state:" <> name) do
    with {:ok, state} <- existing_atom(name), do: {:ok, {:state, state}}
  end

  def parse_breakpoint("decision:" <> name), do: decision_breakpoint(Module.concat(Xeito.Decisions, Macro.camelize(name)))
  def parse_breakpoint("conf<" <> x), do: x |> Float.parse() |> confidence_breakpoint()

  def parse_breakpoint(_spec), do: :error

  defp decision_breakpoint(module), do: if(Code.ensure_loaded?(module), do: {:ok, {:decision, module}}, else: :error)

  defp confidence_breakpoint({f, ""}), do: {:ok, {:confidence_below, f}}
  defp confidence_breakpoint(_parsed), do: :error

  @doc "Updates `live` and `paused` from an event of one of the session's runs."
  @spec track(String.t(), map(), Session.state()) :: Session.state()
  def track(run_id, %{type: "paused"}, s), do: %{s | paused: run_id}

  def track(run_id, %{type: "run_started"}, s) do
    if internal?(run_id), do: s, else: %{s | live: MapSet.put(s.live, run_id)}
  end

  def track(run_id, %{type: "run_finished"}, s),
    do: %{s | live: MapSet.delete(s.live, run_id), paused: unpause(s.paused, run_id)}

  # Streamed pieces can arrive after the run paused: they do not mean it moved on.
  def track(run_id, %{type: type}, s) when type not in ~w(delta output), do: %{s | paused: unpause(s.paused, run_id)}
  def track(_run_id, _event, s), do: s

  defp unpause(run_id, run_id), do: nil
  defp unpause(paused, _run_id), do: paused

  defp internal?(run_id), do: String.ends_with?(run_id, "/esc") or String.ends_with?(run_id, "/intent")
end
