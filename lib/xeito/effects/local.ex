defmodule Xeito.Effects.Local do
  @moduledoc """
  Executes effects on the local machine, confined to the effect's workspace (`:cwd`).

    * `bash` runs `sh -c` in the workspace. Output is merged (stderr into stdout) and
      truncated to `opts[:max_output]` bytes (default 64 KiB). On timeout the result is
      `exit_status: 124` and `timed_out: true`, with the output so far. A timeout or a halt stops the command and every
      process it started (`Xeito.Effects.OsCommand`).
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

  alias Xeito.Backends.Ollama
  alias Xeito.Budget
  alias Xeito.Chat
  alias Xeito.Decider
  alias Xeito.Decision
  alias Xeito.Effect
  alias Xeito.Effects.MiseEnv
  alias Xeito.Effects.OsCommand
  alias Xeito.Escalation
  alias Xeito.Log
  alias Xeito.Policy
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.Tiers
  alias Xeito.Tools
  alias Xeito.Tools.Shape

  @max_output 65_536

  @impl true
  def run(%Effect{kind: :read} = effect, opts), do: file_effect(effect, opts)
  def run(%Effect{kind: kind} = effect, opts) when kind in [:write, :edit, :bash], do: step(effect, opts)

  def run(%Effect{kind: kind} = effect, opts) when kind in [:decide, :tier, :probe, :swap],
    do: decision_effect(effect, opts)

  def run(%Effect{kind: :chat} = effect, opts), do: chat(effect, opts)
  def run(%Effect{kind: :machine} = effect, opts), do: machine(effect, opts)

  # A change to the workspace: a step of its session for /undo, when it changed something and
  # was requested by a run (`Xeito.Undo`). `undo: false` turns this off.
  defp step(%Effect{id: id, args: args} = effect, opts) do
    if is_binary(id) and Keyword.get(opts, :undo, true),
      do: Xeito.Undo.step(workspace!(args), id, label(effect), fn -> change(effect, opts) end, outside: outside(effect)),
      else: change(effect, opts)
  end

  defp change(%Effect{kind: :bash} = effect, opts), do: bash(effect, opts)
  defp change(effect, opts), do: file_effect(effect, opts)

  # The files outside the workspace a command names (`Xeito.Decisions.Risk.written_paths/1`), to
  # back up with the step; `~/` at the start of a word is the home directory, as for the shell.
  defp outside(%Effect{kind: :bash, args: %{cmd: cmd} = args}) do
    cwd = workspace!(args)
    command = String.replace(cmd, ~r{(^|\s)~/}, "\\1#{System.user_home()}/")

    case Xeito.Decisions.Risk.written_paths(command) do
      {:ok, paths} -> paths |> Enum.map(&Path.expand(&1, cwd)) |> Enum.reject(&String.starts_with?(&1, cwd <> "/"))
      :error -> []
    end
  end

  defp outside(_file_effect), do: []

  defp label(%Effect{kind: :bash, args: %{cmd: cmd}}) do
    cmd = cmd |> String.split() |> Enum.join(" ")
    if String.length(cmd) > 60, do: "bash #{String.slice(cmd, 0, 60)}…", else: "bash #{cmd}"
  end

  defp label(%Effect{kind: kind, args: %{path: path}}), do: "#{kind} #{path}"

  defp file_effect(%Effect{kind: :read, args: %{result: ref}}, opts), do: read_back(ref, opts)
  defp file_effect(%Effect{kind: :read} = effect, _opts), do: read(effect)
  defp file_effect(%Effect{kind: :write, args: args}, _opts), do: write(args)
  defp file_effect(%Effect{kind: :edit, args: args}, _opts), do: edit(args)

  # A decision, a tier's answer, and the escalation's model probes and swaps.
  defp decision_effect(%Effect{kind: :decide} = effect, opts), do: decide(effect, opts)
  defp decision_effect(%Effect{kind: :tier, args: args}, opts), do: tier(args, opts)
  defp decision_effect(%Effect{kind: :probe, args: args}, opts), do: probe(args, opts)
  defp decision_effect(%Effect{kind: :swap, args: args}, opts), do: swap(args, opts)

  defp bash(%Effect{args: args} = effect, opts) do
    cwd = workspace!(args)

    if File.dir?(cwd),
      do: effect |> Shape.shape(run_bash(cwd, args, opts)) |> with_ref(effect),
      else: workspace_missing(cwd)
  end

  defp read(%Effect{args: args} = effect) do
    with {:ok, path} <- resolve(args),
         {:ok, content} <- File.read(path),
         {:ok, text} <- view(args, content) do
      effect |> Shape.shape(%{ok: true, content: text}) |> with_ref(effect)
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp write(args) do
    with {:ok, path} <- resolve(args),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, args.content) do
      parsed(args.path, args.content)
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp edit(args) do
    with {:ok, path} <- resolve(args),
         {:ok, content} <- File.read(path),
         {:ok, updated} <- replace_once(content, args.old, args.new),
         :ok <- File.write(path, updated) do
      parsed(args.path, updated)
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp chat(%Effect{args: %{error: reason}}, _opts), do: %{error: {:context_window, reason}}

  defp chat(%Effect{args: args} = effect, opts) do
    on_delta = &Xeito.Events.delta(streamed_to(args, opts), effect.id, &1)

    case Chat.complete(args.messages, specs(args.tools), Keyword.get(opts, :chat, []), on_delta) do
      {:ok, message} -> message
      {:error, reason} -> %{error: reason}
    end
  end

  defp specs(names) when is_list(names), do: Tools.specs(names)
  defp specs(true), do: Tools.specs()
  defp specs(false), do: []

  # A quiet request (a summary) is not streamed: deltas without a run go nowhere.
  defp streamed_to(%{quiet: true}, _opts), do: nil
  defp streamed_to(_args, opts), do: opts[:run_id]

  defp machine(%Effect{args: args} = effect, opts) do
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
        Map.put(%{result | ctx: Map.take(result.ctx, [:answer, :error, :steps, :tokens_in, :tokens_out])}, :run_id, id)

      :timeout ->
        %{run_id: id, status: :timeout, state: nil, ctx: %{}}
    end
  end

  defp decide(%Effect{args: args} = effect, opts) do
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

  defp tier(%{tier: tier} = args, opts) do
    type = Decision.type!(args.decision)

    case Tiers.run(tier, type, args.input, get_in(opts, [:tiers, tier]) || []) do
      {:ok, result} ->
        charge(opts[:parent_run] || parent_of(opts[:run_id]), result)
        Map.put(result, :tier, tier)

      {:error, reason} ->
        %{tier: tier, error: reason}
    end
  end

  defp probe(%{tier: tier} = args, opts) do
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

  defp swap(%{tier: tier} = args, opts) do
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

  defp charge(parent, %{cost: %{usd: usd}}) when is_number(usd) and usd > 0, do: Budget.add(parent, :usd, usd)

  defp charge(_parent, _result), do: :ok

  # Escalation runs are named "<parent effect>/esc"; the parent run is the prefix before "/e".
  defp parent_of(nil), do: nil

  defp parent_of(run_id) do
    case String.split(run_id, "/e", parts: 2) do
      [parent, _] -> parent
      _ -> nil
    end
  end

  # With the workspace's own tool versions, when it pins them with mise (`Xeito.Effects.MiseEnv`).
  defp run_bash(cwd, args, opts) do
    {exe, argv} = MiseEnv.command(cwd, args.cmd)

    case OsCommand.run(exe, argv, cd: cwd, timeout: args.timeout) do
      {:exited, status, output} ->
        %{exit_status: status, output: truncate(MiseEnv.explain(output, status, cwd), opts)}

      {:timeout, output} ->
        stopped = "[timed out after #{args.timeout} ms; the command and its children were stopped]\n"
        %{exit_status: 124, output: truncate(output <> stopped, opts), timed_out: true}
    end
  end

  # The shell's own exit status for "cannot run here", with a message a model or human can act on.
  defp workspace_missing(cwd),
    do: %{exit_status: 127, output: "workspace missing: #{cwd} does not exist (moved or deleted?)"}

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

  # Which effect produced a result, so a model can read it back after it was shaped or elided.
  defp with_ref(result, %Effect{id: id}) when is_binary(id), do: Map.put(result, :ref, id)
  defp with_ref(result, _effect), do: result

  # The full, unshaped result of an earlier effect, from the log: a full effect id
  # (`ses-x/t1/e12`, also from an earlier turn), or `e12` for one of this run.
  defp read_back(ref, opts) do
    {run_id, id} =
      if String.contains?(ref, "/"),
        do: {String.replace(ref, ~r{/e\d+$}, ""), ref},
        else: {opts[:run_id], "#{opts[:run_id]}/#{ref}"}

    with log when log != nil <- opts[:log],
         true <- is_binary(run_id),
         {_, _, {:effect_completed, ^id, result}} <-
           Enum.find(Log.read_run(log, run_id), &match?({_, _, {:effect_completed, ^id, _}}, &1)) do
      %{
        ok: true,
        content: "full output of #{ref}:\n" <> Tools.result_text(Map.drop(result, [:shaped, :ref]))
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
      [] -> {:error, "old_text not found" <> nearest(content, old)}
      many -> {:error, "old_text matches #{length(many)} times; include more context"}
    end
  end

  # A missed edit (usually old text recalled from memory, or with different indentation) is
  # answered with the file's closest region, so the next step can copy it exactly. The region
  # starts at the first line of old_text: an exact match ignoring indentation, else the most
  # similar line (Jaro distance ≥ 0.85).
  @max_region 40
  defp nearest(content, old) do
    lines = String.split(content, "\n")
    old_lines = String.split(old, "\n")
    anchor = old_lines |> Enum.map(&String.trim/1) |> Enum.find("", &(&1 != ""))
    trimmed = Enum.map(lines, &String.trim/1)

    index =
      Enum.find_index(trimmed, &(&1 == anchor)) ||
        trimmed
        |> Enum.with_index()
        |> Enum.map(fn {line, i} -> {String.jaro_distance(line, anchor), i} end)
        |> Enum.max(fn -> {0, nil} end)
        |> then(fn {score, i} -> if anchor != "" and score >= 0.85, do: i end)

    case index do
      nil ->
        "; nothing similar in the file. Re-read the part you want to change."

      i ->
        count = min(length(old_lines) + 2, @max_region)
        region = Enum.slice(lines, i, count)

        "; the closest text is at lines #{i + 1}-#{i + length(region)} (copy it exactly):\n" <>
          Enum.join(region, "\n")
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
