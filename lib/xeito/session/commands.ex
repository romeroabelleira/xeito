defmodule Xeito.Session.Commands do
  @moduledoc """
  The session's slash commands: their names, and the dispatch of a command line to the module for its group.

  `run/2` takes the line without its slash and returns the new session state; the outcome reaches
  the user as events (a `notice`, an `error`, or those of a started run). Commands that start a
  run or a turn go back to `Xeito.Session` for it. An unknown command, or a step-mode command
  missing its argument, emits an error pointing to `/help`.
  """

  alias Xeito.Machines.Chat
  alias Xeito.Machines.Shell
  alias Xeito.Run
  alias Xeito.Session
  alias Xeito.Session.History
  alias Xeito.Session.Info
  alias Xeito.Session.Input
  alias Xeito.Session.Notify
  alias Xeito.Session.Queue
  alias Xeito.Session.Review
  alias Xeito.Session.Router
  alias Xeito.Session.StepMode
  alias Xeito.Session.UndoCommand
  alias Xeito.Skills

  # By group (run/2); `skill:` is a prefix.
  @start_commands ~w(machine run skill: steer)
  @turn_commands ~w(approve deny halt send drop)
  @info_commands ~w(why budget model help machines)
  @debug_commands ~w(step continue next decide break)
  @undo_commands ~w(undo redo)

  @command_groups Map.new(
                    for {group, names} <- [
                          start: @start_commands,
                          turn: @turn_commands,
                          info: @info_commands,
                          debug: @debug_commands,
                          undo: @undo_commands
                        ],
                        name <- names,
                        do: {name, group}
                  )

  @doc "The slash commands the session takes, without the slash."
  @spec names() :: [String.t()]
  def names, do: @start_commands ++ @turn_commands ++ @info_commands ++ @debug_commands ++ @undo_commands

  @doc "Runs a slash command, given without its slash."
  @spec run(String.t(), Session.state()) :: Session.state()
  def run(command, s), do: run(String.split(command, ~r/\s+/, parts: 2) ++ [""], command, s)

  defp run([name, arg | _], raw, s) do
    case command_group(name) do
      :start -> start_command(name, arg, s)
      :turn -> turn_command(name, arg, s)
      :info -> Info.command(name, arg, s)
      :debug -> debug_command(name, arg, raw, s)
      :undo -> UndoCommand.run(name, arg, s)
      nil -> unknown_command(raw, s)
    end
  end

  defp command_group("skill:" <> _name), do: :start
  defp command_group(name), do: @command_groups[name]

  defp start_command("machine", rest, s), do: machine_command(rest, s)
  defp start_command("skill:" <> name, rest, s), do: skill_command(name, rest, s)
  defp start_command("run", "", s), do: Notify.error(s, "/run <command>: a shell command to run in the workspace")

  defp start_command("steer", "", s),
    do: Notify.error(s, "/steer <text>: a line for the running chat turn, taken at its next model call")

  defp start_command("steer", text, s), do: steer(text, s)
  defp start_command("run", cmd, s), do: Session.start_machine(Shell, Input.for_machine(Shell, cmd, s), "/run", s)

  defp turn_command("halt", _arg, s), do: halt(s)
  defp turn_command(send_or_drop, _arg, s) when send_or_drop in ["send", "drop"], do: queue_command(send_or_drop, s)
  defp turn_command(approve_or_deny, arg, s), do: Review.command(approve_or_deny, arg, s)

  defp queue_command(_send_or_drop, %{queue: []} = s), do: Notify.error(s, "nothing is queued")

  defp queue_command("send", %{root: root} = s) when root != nil,
    do: Notify.error(s, "a turn is running; queued lines are sent when it ends")

  defp queue_command("send", s), do: Session.send_queued(s)
  defp queue_command("drop", s), do: Queue.dequeue(s, "dropped")

  defp debug_command("step", _arg, _raw, s), do: StepMode.set_debug(%{s.debug | step: not s.debug.step}, s)
  defp debug_command("continue", _arg, _raw, s), do: StepMode.set_debug(%{s.debug | step: false}, s)
  defp debug_command("next", _arg, _raw, s), do: StepMode.step(:next, s)
  defp debug_command(name, arg, raw, s), do: debug_arg_command(name, arg, raw, s)

  defp debug_arg_command(_name, "", raw, s), do: unknown_command(raw, s)
  defp debug_arg_command("decide", value, _raw, s), do: StepMode.step({:decide, value}, s)
  defp debug_arg_command("break", "clear", _raw, s), do: StepMode.set_debug(%{s.debug | breakpoints: []}, s)
  defp debug_arg_command("break", spec, _raw, s), do: StepMode.add_breakpoint(spec, s)

  defp unknown_command(raw, s), do: Notify.error(s, "unknown command /#{raw}; try /help")

  defp machine_command(rest, s) do
    [name | prompt] = String.split(rest, ~r/\s+/, parts: 2) ++ [""]

    case Router.machines() do
      %{^name => machine} ->
        Session.start_machine(machine, Input.for_machine(machine, Enum.join(prompt), s), "/machine", s)

      machines ->
        Notify.error(
          s,
          "unknown machine #{inspect(name)}; available: #{Enum.join(Map.keys(machines), ", ")}"
        )
    end
  end

  # `/skill:name args`: the skill's instructions become the prompt of a chat turn.
  defp skill_command(name, request, s) do
    case Enum.find(Skills.discover(s.cwd), &(&1.name == name)) do
      nil ->
        Notify.error(s, "no skill named #{inspect(name)}")

      skill ->
        input = Map.put(Input.for_machine(Chat, Skills.invocation(skill, request), s), :skill_candidates, [])
        Session.start_machine(Chat, input, "/skill:#{name}", s)
    end
  end

  # Idle, a steer is a prompt; during a machine other than chat, it is queued.
  defp steer(text, %{root: nil} = s), do: Session.start_turn(text, String.trim(text), s)
  defp steer(text, s), do: Queue.steer(text, s)

  # Stops the run and the runs under it, or the intent decision before any run started.
  defp halt(%{root: nil} = s), do: Notify.error(s, "nothing is running")

  defp halt(%{root: :deciding} = s) do
    Notify.emit(s, "turn_finished", nil, %{"status" => :halted, "final_state" => :intent, "answer" => History.halted()})
    Queue.hold(%{s | root: nil}, "halted")
  end

  defp halt(s) do
    case Run.halt(s.root) do
      :ok -> s
      {:error, :not_running} -> Notify.error(s, "nothing is running")
    end
  end
end
