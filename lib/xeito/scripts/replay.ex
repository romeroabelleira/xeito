defmodule Xeito.Scripts.Replay do
  @moduledoc """
  A script run again against the log: what its calls got the first time, fed to it in order
  (`Xeito.Effects.Script`), and the check that it asks for the same calls.

    * `logged/2` reads a script's child effects out of a run's log entries: the finished ones with
      their results, in the order they were asked (`replay`), and the one the run was in when it
      stopped, if any (`incomplete`). A call begun and abandoned earlier is dropped when it ran
      again (it may, `Xeito.Effect.replay/1`), else fed as `:interrupted`, as the script was told.
    * `feed/2` serves the next call from that: the logged result when it is the same call
      (`same?/2`: kind and arguments, not a command's time limit), `{:desync, logged}` when it is
      not, `{:interrupted, id, state}` for an abandoned call that may not run again, and `:live`
      past the log.
    * `verify/2` runs each finished script of a run again in a sandbox, fed its log, and reports
      the first call that differs (`{:desync, id}`), a result that differs (`{:desync, script id}`),
      or `:ok`. `mix xeito.log verify` uses it.
  """

  alias Xeito.Effect
  alias Xeito.Effects.Script
  alias Xeito.Scripts.Sandbox

  @type entry :: {pos_integer(), String.t(), term()}
  @type logged :: %{replay: [{Effect.t(), map() | :interrupted}], incomplete: Effect.t() | nil}
  @type state :: %{
          required(:replay) => [{Effect.t(), map() | :interrupted}],
          required(:incomplete) => Effect.t() | nil,
          optional(atom()) => term()
        }

  @doc "The child effects of script `id` in `entries`, with their results, and the one left unfinished."
  @spec logged([entry()], String.t()) :: logged()
  def logged(entries, id) do
    {results, order} =
      Enum.reduce(entries, {%{}, []}, fn
        {_, "effect_requested", {:effect_requested, %Effect{id: child} = effect}}, {results, order} ->
          if Effect.parent(child) == id, do: {results, [effect | order]}, else: {results, order}

        {_, "effect_completed", {:effect_completed, child, result}}, {results, order} ->
          if Effect.parent(child) == id, do: {Map.put(results, child, result), order}, else: {results, order}

        _other, acc ->
          acc
      end)

    sort(Enum.reverse(order), results)
  end

  # The last request without a result is where the run stopped; an earlier one was abandoned.
  defp sort(order, results) do
    case Enum.reverse(order) do
      [%Effect{id: last} = effect | _] when not is_map_key(results, last) ->
        %{replay: fed(Enum.drop(order, -1), results), incomplete: effect}

      _ ->
        %{replay: fed(order, results), incomplete: nil}
    end
  end

  defp fed(order, results) do
    Enum.flat_map(order, fn %Effect{id: id} = effect ->
      cond do
        is_map_key(results, id) -> [{effect, results[id]}]
        Effect.replay(effect) == :safe -> []
        true -> [{effect, :interrupted}]
      end
    end)
  end

  @doc "The next call of a script run again: fed, a desync, interrupted, or live past the log."
  @spec feed(state(), Effect.t()) ::
          {:logged, map(), state()} | {:desync, Effect.t()} | {:interrupted, String.t(), state()} | {:live, state()}
  def feed(%{replay: [{logged, result} | rest]} = state, asked),
    do: if(same?(asked, logged), do: fed(result, logged, %{state | replay: rest}), else: {:desync, logged})

  def feed(%{replay: [], incomplete: %Effect{} = logged} = state, asked),
    do: if(same?(asked, logged), do: abandoned(logged, %{state | incomplete: nil}), else: {:desync, logged})

  def feed(state, _asked), do: {:live, state}

  defp fed(:interrupted, logged, state), do: {:interrupted, logged.id, state}
  defp fed(result, _logged, state), do: {:logged, result, state}

  # The call the run was in when it stopped: run again when it may, else the script is told.
  defp abandoned(logged, state),
    do: if(Effect.replay(logged) == :safe, do: {:live, state}, else: {:interrupted, logged.id, state})

  @doc "Whether two calls are the same: kind and arguments, but not a command's time limit, which is what was left then."
  @spec same?(Effect.t(), Effect.t()) :: boolean()
  def same?(%Effect{kind: kind, args: a}, %Effect{kind: kind, args: b}),
    do: Map.delete(a, :timeout) == Map.delete(b, :timeout)

  def same?(_asked, _logged), do: false

  @doc "A call in a few words, for a desync message."
  @spec describe(Effect.t()) :: String.t()
  def describe(%Effect{kind: :read, args: %{path: path}}), do: ~s(read "#{path}")
  def describe(%Effect{kind: :bash, args: %{cmd: cmd}}), do: ~s(bash "#{cmd}")
  def describe(%Effect{kind: kind, args: %{path: path}}) when kind in [:write, :edit], do: ~s(#{kind} "#{path}")
  def describe(%Effect{kind: :decide, args: %{decision: type}}), do: "decide " <> Xeito.Decision.describe(type)
  def describe(%Effect{kind: :remember, args: %{id: id}}), do: ~s(remember "#{id}")
  def describe(%Effect{kind: kind}), do: Atom.to_string(kind)

  @doc "The finished scripts of a run, each with its logged result."
  @spec scripts([entry()]) :: [{Effect.t(), map()}]
  def scripts(entries) do
    results = for {_, "effect_completed", {:effect_completed, id, result}} <- entries, into: %{}, do: {id, result}

    for {_, "effect_requested", {:effect_requested, %Effect{kind: :script, id: id} = effect}} <- entries,
        is_map_key(results, id),
        do: {effect, results[id]}
  end

  @doc """
  Runs each finished script of a run again in `sandbox`, fed its log. `:ok`, `{:desync, id}` or
  `{:error, reason}`, with the sandbox (`nil` once a VM failed; `Xeito.Scripts.Sandbox.start/1`
  gives the next one).
  """
  @spec verify([entry()], Sandbox.t()) :: {:ok | {:desync, String.t()} | {:error, term()}, Sandbox.t() | nil}
  def verify(entries, sandbox) do
    Enum.reduce_while(scripts(entries), {:ok, sandbox}, fn {effect, logged}, {:ok, sandbox} ->
      case verify_one(entries, effect, logged, sandbox) do
        {:ok, sandbox} -> {:cont, {:ok, sandbox}}
        {failed, sandbox} -> {:halt, {failed, sandbox}}
      end
    end)
  end

  defp verify_one(entries, %Effect{id: id, args: args} = effect, logged, sandbox) do
    %{replay: replay, incomplete: incomplete} = logged(entries, id)
    beyond = Effect.child_id(id, length(replay) + 1)

    past_the_log = fn _parent, asked ->
      {:desync, beyond, "desync at #{beyond}: the log ends, the script asked for #{describe(asked)}"}
    end

    acc = Script.start(effect, child: past_the_log, replay: replay, incomplete: incomplete)
    {outcome, sandbox, acc} = Sandbox.eval(sandbox, args.code, %{"timeout_ms" => args.timeout}, acc, &Script.handle/3)
    {verdict(effect, Script.finish(effect, outcome, acc), logged, acc), sandbox}
  end

  # One of the two is there in any result: a differing `ok` shows in them.
  @compared [:content, :error]

  defp verdict(_effect, _result, _logged, %{desync: id}) when is_binary(id), do: {:desync, id}
  defp verdict(_effect, _result, _logged, %{stopped: reason}) when is_binary(reason), do: {:error, reason}

  defp verdict(%Effect{id: id}, result, logged, _acc),
    do: if(Map.take(result, @compared) == Map.take(logged, @compared), do: :ok, else: {:desync, id})
end
