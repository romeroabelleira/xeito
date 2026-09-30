defmodule Xeito.Effects.Local do
  @moduledoc """
  Executes effects on the local machine, confined to the effect's workspace (`:cwd`).

    * `bash` runs `sh -c` in the workspace. Output is merged (stderr into stdout) and
      truncated to `opts[:max_output]` bytes (default 64 KiB). On timeout the result is
      `exit_status: 124`.
    * `read` / `write` / `edit` resolve paths relative to the workspace and refuse anything
      outside it. `edit` replaces exactly one occurrence of the old text, or fails.
    * `chat` runs one chat-model turn with the core tools (`Xeito.Chat`) and streams its output
      to `Xeito.Events`. `opts[:chat]` overrides the chat model configuration.
    * `machine` runs another machine to completion as a child run (`<effect id>/run`, related
      `part_of` the requesting run) with this same runner, and returns its outcome.
    * `decide` runs the decision as an escalation machine (`Xeito.Escalation`), a child run in
      the same log, when the runner was dispatched by a run (`opts[:log]`). Without a log it
      falls back to the in-process `Xeito.Decider`. `opts[:decider]` passes options (deciders,
      policy, tier overrides), and `opts[:decide]` (`fun(effect) -> value`) overrides both (tests).
    * `tier`, `probe` and `swap` are the escalation machine's own effects: one tier call through
      its capacity queue, a residency check, and a model load. Remote spend and swaps are
      charged to the parent run's `Xeito.Budget`.
  """

  @behaviour Xeito.Effects.Runner

  alias Xeito.{Budget, Chat, Decider, Decision, Effect, Escalation, Log, Policy}
  alias Xeito.{Run, RunSupervisor, Tiers, Tools}
  alias Xeito.Tiers.Ollama
  alias Xeito.Tools.Shape

  @max_output 65_536

  @impl true
  def run(%Effect{kind: :bash, args: args} = effect, opts) do
    cwd = workspace!(args)

    if File.dir?(cwd),
      do: Shape.shape(effect, run_bash(cwd, args, opts)),
      else: workspace_missing(cwd)
  end

  def run(%Effect{kind: :read, args: %{result: ref}}, opts), do: read_back(ref, opts)

  def run(%Effect{kind: :read, args: args} = effect, _opts) do
    with {:ok, path} <- resolve(args),
         {:ok, content} <- File.read(path),
         {:ok, text} <- view(args, content) do
      Shape.shape(effect, %{ok: true, content: text})
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  def run(%Effect{kind: :write, args: args}, _opts) do
    with {:ok, path} <- resolve(args),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, args.content) do
      parsed(args.path, args.content)
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  def run(%Effect{kind: :edit, args: args}, _opts) do
    with {:ok, path} <- resolve(args),
         {:ok, content} <- File.read(path),
         {:ok, updated} <- replace_once(content, args.old, args.new),
         :ok <- File.write(path, updated) do
      parsed(args.path, updated)
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  def run(%Effect{kind: :chat, args: args} = effect, opts) do
    tools =
      case args.tools do
        names when is_list(names) -> Tools.specs(names)
        true -> Tools.specs()
        false -> []
      end

    on_delta = &Xeito.Events.delta(opts[:run_id], effect.id, &1)

    case Chat.complete(args.messages, tools, Keyword.get(opts, :chat, []), on_delta) do
      {:ok, message} -> message
      {:error, reason} -> %{error: reason}
    end
  end

  def run(%Effect{kind: :machine, args: args} = effect, opts) do
    log = Keyword.fetch!(opts, :log)
    id = effect.id <> "/run"
    runner = {__MODULE__, opts |> Keyword.put(:run_id, id) |> Keyword.delete(:debug)}

    # A delegated run inherits the requesting run's step mode and breakpoints.
    start = [run_id: id, log: log, runner: runner, debug: opts[:debug]]

    case RunSupervisor.start_run(args.machine, args.input, start) do
      {:ok, ^id} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if opts[:run_id], do: Log.relate(log, id, opts[:run_id], "part_of")

    case Run.await(log, id, args.timeout) do
      # The child's full context stays in its own log; the parent gets the outcome.
      {:ok, result} ->
        %{result | ctx: Map.take(result.ctx, [:answer, :error, :steps, :tokens_in, :tokens_out])}
        |> Map.put(:run_id, id)

      :timeout ->
        %{run_id: id, status: :timeout, state: nil, ctx: %{}}
    end
  end

  def run(%Effect{kind: :decide, args: args} = effect, opts) do
    decider = Keyword.get(opts, :decider, [])

    cond do
      fun = opts[:decide] ->
        %{value: fun.(effect)}

      log = opts[:log] ->
        escalation =
          [log: log, parent: opts[:run_id], effect_id: effect.id] ++
            Keyword.take(decider, [:deciders, :policy, :tiers, :available?])

        decision = Escalation.decide(args.decision, args.input, escalation)
        %{value: decision.value, decision: Decision.to_map(decision)}

      true ->
        decision = Decider.decide(args.decision, args.input, decider)
        %{value: decision.value, decision: Decision.to_map(decision)}
    end
  end

  def run(%Effect{kind: :tier, args: %{tier: tier} = args}, opts) do
    type = Decision.type!(args.decision)

    case Tiers.run(tier, type, args.input, get_in(opts, [:tiers, tier]) || []) do
      {:ok, result} ->
        charge(opts[:parent_run] || parent_of(opts[:run_id]), result)
        Map.put(result, :tier, tier)

      {:error, reason} ->
        %{tier: tier, error: reason}
    end
  end

  def run(%Effect{kind: :probe, args: %{tier: tier} = args}, opts) do
    case Tiers.config(tier, get_in(opts, [:tiers, tier]) || []) do
      nil ->
        %{loaded: false, swap_allowed: false, error: :tier_unavailable}

      cfg ->
        case Ollama.loaded?(cfg) do
          {:ok, loaded} ->
            %{loaded: loaded, swap_allowed: Policy.swap_allowed?(args.policy, args.parent)}

          {:error, reason} ->
            %{loaded: false, swap_allowed: false, error: reason}
        end
    end
  end

  def run(%Effect{kind: :swap, args: %{tier: tier} = args}, opts) do
    with cfg when cfg != nil <- Tiers.config(tier, get_in(opts, [:tiers, tier]) || []),
         {:ok, ms} <- Ollama.load(cfg) do
      if args.parent, do: Budget.add(args.parent, :swaps, 1)
      %{ok: true, ms: ms}
    else
      nil -> %{ok: false, error: :tier_unavailable}
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  # Remote spend counts against the run that asked for the decision.
  defp charge(nil, _result), do: :ok

  defp charge(parent, %{cost: %{usd: usd}}) when is_number(usd) and usd > 0,
    do: Budget.add(parent, :usd, usd)

  defp charge(_parent, _result), do: :ok

  # Escalation runs are named "<parent effect>/esc"; the parent run is the prefix before "/e".
  defp parent_of(nil), do: nil

  defp parent_of(run_id) do
    case String.split(run_id, "/e", parts: 2) do
      [parent, _] -> parent
      _ -> nil
    end
  end

  defp run_bash(cwd, args, opts) do
    task =
      Task.async(fn -> System.cmd("sh", ["-c", args.cmd], cd: cwd, stderr_to_stdout: true) end)

    case Task.yield(task, args.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> %{exit_status: status, output: truncate(output, opts)}
      nil -> %{exit_status: 124, output: "timed out after #{args.timeout} ms"}
    end
  end

  # The shell's own exit status for "cannot run here", with a message a model or human can act on.
  defp workspace_missing(cwd),
    do: %{
      exit_status: 127,
      output: "workspace missing: #{cwd} does not exist (moved or deleted?)"
    }

  defp view(%{lines: range, path: path}, content), do: slice(path, content, range)
  defp view(%{symbol: name, path: path}, content), do: Xeito.Source.symbol(path, content, name)
  defp view(%{outline: true, path: path}, content), do: Xeito.Source.outline(path, content)
  defp view(_args, content), do: {:ok, content}

  # `lines: "120-400"` (or `"120"`, to the end), headed by the range read.
  defp slice(path, content, range) do
    lines = String.split(content, "\n")
    total = length(lines)

    case Regex.run(~r/^\s*(\d+)\s*(?:-\s*(\d+))?\s*$/, range) do
      [_, from | to] ->
        from = max(String.to_integer(from), 1)
        to = min(if(to == [], do: total, else: to |> hd() |> String.to_integer()), total)

        if from > to,
          do: {:error, "lines #{range} is outside #{path} (#{total} lines)"},
          else:
            {:ok,
             "#{path} lines #{from}-#{to} of #{total}:\n" <>
               Enum.join(Enum.slice(lines, (from - 1)..(to - 1)//1), "\n")}

      nil ->
        {:error, ~s(lines must look like "120-400" or "120", got #{inspect(range)})}
    end
  end

  # The full, unshaped result of an earlier effect of this run, from the log.
  defp read_back(ref, opts) do
    with log when log != nil <- opts[:log],
         run_id when is_binary(run_id) <- opts[:run_id],
         id = "#{run_id}/#{ref}",
         {_, _, {:effect_completed, ^id, result}} <-
           Enum.find(Log.read_run(log, run_id), &match?({_, _, {:effect_completed, ^id, _}}, &1)) do
      %{
        ok: true,
        content: "full output of #{ref}:\n" <> Tools.result_text(Map.delete(result, :shaped))
      }
    else
      _ -> %{ok: false, error: "no result #{inspect(ref)} in this run"}
    end
  end

  # A write or edit is applied either way; a file that no longer parses is reported at once, so
  # the model fixes it in its next step rather than after the turn.
  defp parsed(path, content) do
    case Xeito.Source.syntax_error(path, content) do
      nil -> %{ok: true}
      error -> %{ok: true, syntax_error: error}
    end
  end

  defp replace_once(_content, "", _new), do: {:error, "old_text is empty"}

  defp replace_once(content, old, new) do
    case :binary.matches(content, old) do
      [_] -> {:ok, String.replace(content, old, new, global: false)}
      [] -> {:error, "old_text not found"}
      many -> {:error, "old_text matches #{length(many)} times; include more context"}
    end
  end

  @doc "Resolves `args.path` inside the workspace, or returns `{:error, :outside_workspace}`."
  @spec resolve(map()) :: {:ok, Path.t()} | {:error, :outside_workspace}
  def resolve(%{path: path} = args) do
    root = workspace!(args)
    full = Path.expand(path, root)

    if full == root or String.starts_with?(full, root <> "/"),
      do: {:ok, full},
      else: {:error, :outside_workspace}
  end

  defp workspace!(%{cwd: cwd}) when is_binary(cwd), do: Path.expand(cwd)
  defp workspace!(_), do: raise(ArgumentError, "effect has no workspace (:cwd)")

  defp truncate(output, opts) do
    max = Keyword.get(opts, :max_output, @max_output)

    if byte_size(output) > max,
      do: binary_part(output, byte_size(output) - max, max),
      else: output
  end
end
