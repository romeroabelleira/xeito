defmodule Xeito.Effects.Script do
  @moduledoc """
  Runs a `script` effect: the program in the session's sandbox VM (`Xeito.Scripts.Host`), each
  of its calls to the outside as a child effect of the script's, and its output as the result.

    * `read` and `bash` calls become child effects (`Xeito.Effect.child_id/2`) that the run
      requests, logs and completes like its own (`Xeito.Run.child/3`; `opts[:child]` replaces
      it in tests). The script sees each result as JSON carries it, without the model's shaping.
    * `bash` runs only a command `Xeito.Decisions.Risk`'s rules call safe. One they would send
      to review fails that call with an error saying so; a forbidden one stops the script, and
      every later call fails with the reason.
    * A command's time limit is what is left of the script's (`args.timeout`), at least a second.
    * `text` adds a line to the output and streams it to clients as a command's output;
      `now` and `random` come from the runner.
    * The result: `%{ok: true, content: output, ref: id}` (what the script printed, its texts,
      its last value), shaped by `Xeito.Tools.Shape` when long; or `%{ok: false, error: reason}`
      naming the failure (`restricted`, `timeout`, `exception`, …, or `stopped`) with the output so far.

  A halted run takes the session's sandbox with it; the next script starts a new one.
  """

  alias Xeito.Decisions.Risk
  alias Xeito.Effect
  alias Xeito.Run
  alias Xeito.Scripts.Host
  alias Xeito.Scripts.Protocol
  alias Xeito.Tools.Shape

  @type acc :: %{
          effect: Effect.t(),
          cwd: Path.t(),
          run_id: String.t() | nil,
          child: (String.t(), Effect.t() -> map()),
          deadline: integer(),
          texts: [String.t()],
          stopped: String.t() | nil
        }

  @min_command_ms 1_000

  @doc "Runs the script of `effect` in the sandbox of the session `opts[:run_id]` belongs to."
  @spec run(Effect.t(), keyword()) :: map()
  def run(%Effect{args: args} = effect, opts) do
    acc = start(effect, opts)
    limits = %{"timeout_ms" => args.timeout}
    {outcome, acc} = Host.eval(session(opts[:run_id]), args.code, limits, acc, &handle/3)
    finish(effect, outcome, acc)
  end

  # The session a run belongs to: the first segment of its id.
  defp session(nil), do: ""
  defp session(run_id), do: run_id |> String.split("/", parts: 2) |> hd()

  @doc "The accumulator a script starts with; `opts[:child]` runs its child effects (the run's `child/3` by default)."
  @spec start(Effect.t(), keyword()) :: acc()
  def start(%Effect{args: args} = effect, opts) do
    run_id = opts[:run_id]

    %{
      effect: effect,
      cwd: Path.expand(args.cwd),
      run_id: run_id,
      child: Keyword.get(opts, :child, &Run.child(run_id, &1, &2)),
      deadline: System.monotonic_time(:millisecond) + args.timeout,
      texts: [],
      stopped: nil
    }
  end

  @doc "One call from the script (`Xeito.Scripts.Api`): the value it gets, and the accumulator after it."
  @spec handle(String.t(), [term()], acc()) :: {term(), acc()}
  def handle(_name, _args, %{stopped: reason} = acc) when is_binary(reason), do: {error("stopped: " <> reason), acc}
  def handle(name, args, acc), do: call(name, args, acc)

  defp call("read", [path], acc) when is_binary(path), do: {child(acc, Effect.read(path, cwd: acc.cwd)), acc}
  defp call("read", _args, acc), do: {error("read takes a path"), acc}
  defp call("bash", [command], acc) when is_binary(command), do: bash(command, acc)
  defp call("bash", _args, acc), do: {error("bash takes a command"), acc}
  defp call("text", [value], acc), do: text(value, acc)
  defp call(name, args, acc), do: runner(name, args, acc)

  # What only the runner has: the clock and randomness, logged so a replay sees the same.
  defp runner("now", [], acc), do: {System.system_time(:millisecond), acc}
  defp runner("random", [], acc), do: {:rand.uniform(), acc}
  defp runner(name, args, acc), do: {error("unknown call #{name}/#{length(args)}"), acc}

  defp bash(command, acc) do
    case Risk.assess(command, acc.cwd).verdict do
      :safe ->
        {child(acc, Effect.bash(command, cwd: acc.cwd, timeout: remaining(acc))), acc}

      :forbidden ->
        reason = "`#{command}` is forbidden"
        {error("stopped: " <> reason), %{acc | stopped: reason}}

      nil ->
        {error(
           "not run: `#{command}` would need a review, and a script may run only commands " <>
             "that are safe by rule; run it as a bash tool call instead"
         ), acc}
    end
  end

  defp remaining(%{deadline: deadline}), do: max(deadline - System.monotonic_time(:millisecond), @min_command_ms)

  # The result as the script sees it: string keys, without the model's shaping and reference.
  defp child(acc, effect), do: acc.effect.id |> acc.child.(effect) |> Map.drop([:shaped, :ref]) |> Protocol.jsonable()

  defp text(value, acc) do
    line = render(value)
    Xeito.Events.output(acc.run_id, acc.effect.id, line <> "\n")
    {line, %{acc | texts: [line | acc.texts]}}
  end

  defp render(value) when is_binary(value), do: value
  defp render(value), do: inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)

  defp error(message), do: %{"ok" => false, "error" => message}

  @doc "The script's outcome (`Xeito.Scripts.Vm.outcome/0`) as the effect's result."
  @spec finish(Effect.t(), Xeito.Scripts.Vm.outcome(), acc()) :: map()
  def finish(effect, _outcome, %{stopped: reason}) when is_binary(reason), do: failed(effect, "stopped: " <> reason, "")

  def finish(effect, {:ok, value, stdio}, acc) do
    content = output(stdio, acc.texts, value && render(value))
    effect |> Shape.shape(%{ok: true, content: content}) |> Map.put(:ref, effect.id)
  end

  def finish(effect, {:error, %{type: type, message: message} = failure}, acc),
    do: failed(effect, "#{type}: #{message}", output(failure[:stdio], acc.texts, nil))

  # What the script printed, its texts, then its last value, one per line; nothing for empties.
  defp output(stdio, texts, value) do
    [stdio | Enum.reverse(texts, [value])]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join("\n", &String.trim_trailing(&1, "\n"))
  end

  defp failed(_effect, reason, ""), do: %{ok: false, error: reason}
  defp failed(_effect, reason, so_far), do: %{ok: false, error: reason <> "\n\noutput so far:\n" <> so_far}
end
