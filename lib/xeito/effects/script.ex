defmodule Xeito.Effects.Script do
  @moduledoc """
  Runs a `script` effect: the program in the session's sandbox VM (`Xeito.Scripts.Host`), each
  of its calls to the outside as a child effect of the script's, and its output as the result.

    * `read` and `bash` calls become child effects (`Xeito.Effect.child_id/2`) that the run
      requests, logs and completes like its own (`Xeito.Run.child/3`; `opts[:child]` replaces
      it in tests). The script gets each result as `Xeito.Scripts.Api` shapes it for Elixir
      code, from the runner's answer as JSON carries it, without the model's shaping.
    * `bash` runs only a command `Xeito.Decisions.Risk`'s rules call safe. One they would send
      to review fails that call with an error saying so; a forbidden one stops the script, and
      every later call fails with the reason.
    * A command's time limit is what is left of the script's (`args.timeout`), at least a second.
    * `write` and `edit` are child effects too, refused in the directories the tools refuse
      (`Xeito.Tools.refused/2`); the script's effect is the one undo step for all of them.
    * `decide` runs a registered decision type by name and `classify` one `Xeito.Decisions.AdHoc`
      type per question, each a child `decide` effect through the escalation ladder; the script
      gets the value, the confidence, the actor and the model. `remember` writes an object to
      the run's log through a child effect.
    * `mcp` calls a tool of the workspace's MCP servers (`Xeito.Mcp`) as a child effect, when
      the rules call it safe (read-only, closed world; `Xeito.Mcp.Tool.risk/1`) and the policy
      allows it (an open-world tool needs the `network` setting); `search_tools` finds tools by
      words. The tools come from `opts[:tools]`, else the workspace's servers.
    * `text` adds a line to the output and streams it to clients as a command's output;
      `now` and `random` are child effects too (`Xeito.Effect.now/0`, `random/0`), so the log
      has what the script saw.
    * A script run again (a recovered run, `mix xeito.log verify`) is fed the logged results of
      its calls, in order (`Xeito.Scripts.Replay`): a call that differs from the logged one at
      the same place stops the script as a desync naming that call; a script logged under
      another sandbox (`args.sandbox`) is not run again.
    * The result: `%{ok: true, content: output, ref: id}` (what the script printed, its texts,
      its last value), shaped by `Xeito.Tools.Shape` when long; or `%{ok: false, error: reason}`
      naming the failure (`restricted`, `timeout`, `exception`, …, or `stopped`) with the output so far;
      an exception on `Jason` says that `JSON` is built in.

  A halted run takes the session's sandbox with it; the next script starts a new one.
  """

  alias Xeito.Decision
  alias Xeito.Decisions
  alias Xeito.Decisions.AdHoc
  alias Xeito.Decisions.Risk
  alias Xeito.Effect
  alias Xeito.Log
  alias Xeito.Mcp
  alias Xeito.Mcp.Tool
  alias Xeito.Policy
  alias Xeito.Run
  alias Xeito.Scripts.Allowlist
  alias Xeito.Scripts.Host
  alias Xeito.Scripts.Protocol
  alias Xeito.Scripts.Replay
  alias Xeito.Tools
  alias Xeito.Tools.Shape

  @type acc :: %{
          effect: Effect.t(),
          cwd: Path.t(),
          run_id: String.t() | nil,
          child: (String.t(), Effect.t() -> map()),
          deadline: integer(),
          texts: [String.t()],
          stopped: String.t() | nil,
          desync: String.t() | nil,
          replay: [{Effect.t(), map() | :interrupted}],
          incomplete: Effect.t() | nil,
          tools: [Mcp.tool()],
          network: term()
        }

  @type child :: (String.t(), Effect.t() -> map() | {:desync, String.t(), String.t()})

  @min_command_ms 1_000

  @doc "Runs the script of `effect` in the sandbox of the session `opts[:run_id]` belongs to."
  @spec run(Effect.t(), keyword()) :: map()
  def run(%Effect{args: args} = effect, opts) do
    acc = start(effect, opts)
    limits = %{"timeout_ms" => args.timeout}

    {outcome, acc} =
      if acc.stopped,
        do: {{:ok, nil, ""}, acc},
        else: Host.eval(session(opts[:run_id]), args.code, limits, acc, &handle/3)

    finish(effect, outcome, acc)
  end

  # The session a run belongs to: the first segment of its id.
  defp session(nil), do: ""
  defp session(run_id), do: run_id |> String.split("/", parts: 2) |> hd()

  @doc """
  The accumulator a script starts with. `opts[:child]` runs its child effects (the run's
  `child/3` by default; it may answer `{:desync, id, reason}` to stop the script). What to feed
  it comes from `opts[:replay]` and `opts[:incomplete]`, or from the run's log (`opts[:log]`,
  `opts[:run_id]`) when the run was `recovered`.
  """
  @spec start(Effect.t(), keyword()) :: acc()
  def start(%Effect{args: args} = effect, opts) do
    run_id = opts[:run_id]
    logged = logged(effect, opts)
    cwd = args.cwd

    %{
      effect: effect,
      cwd: Path.expand(cwd),
      run_id: run_id,
      child: Keyword.get(opts, :child, &Run.child(run_id, &1, &2)),
      deadline: System.monotonic_time(:millisecond) + args.timeout,
      texts: [],
      stopped: sandbox_changed(effect),
      desync: nil,
      replay: logged.replay,
      incomplete: logged.incomplete,
      tools: Keyword.get_lazy(opts, :tools, fn -> cwd |> Path.expand() |> Mcp.tools() |> elem(0) end),
      network: Keyword.get_lazy(opts, :network, fn -> Policy.effective().network end)
    }
  end

  defp logged(effect, opts) do
    cond do
      Keyword.has_key?(opts, :replay) -> %{replay: opts[:replay], incomplete: opts[:incomplete]}
      opts[:recovered] && opts[:log] -> Replay.logged(Log.read_run(opts[:log], opts[:run_id]), effect.id)
      true -> %{replay: [], incomplete: nil}
    end
  end

  # A script must see the allow-list it was written for; one from an old log (a replay) may not.
  defp sandbox_changed(%Effect{args: args}) do
    current = Allowlist.fingerprint()

    if args[:sandbox] == current,
      do: nil,
      else: "the sandbox changed since this script ran (#{args[:sandbox]} is now #{current}): not run again"
  end

  @doc "One call from the script (`Xeito.Scripts.Api`): the value it gets, and the accumulator after it."
  @spec handle(String.t(), [term()], acc()) :: {term(), acc()}
  def handle(_name, _args, %{stopped: reason} = acc) when is_binary(reason), do: {error("stopped: " <> reason), acc}
  def handle(name, args, acc), do: call(name, args, acc)

  defp call("read", [path], acc) when is_binary(path), do: child(acc, Effect.read(path, cwd: acc.cwd))
  defp call("read", _args, acc), do: {error("read takes a path"), acc}
  defp call("bash", [command], acc) when is_binary(command), do: bash(command, acc)
  defp call("bash", _args, acc), do: {error("bash takes a command"), acc}
  defp call("text", [value], acc), do: text(value, acc)
  defp call(name, args, acc), do: extended(name, args, acc)

  defp extended("write", args, acc), do: write(args, acc)
  defp extended("edit", args, acc), do: edit(args, acc)
  defp extended("decide", args, acc), do: decide(args, acc)
  # --- writes --------------------------------------------------------------------------------
  defp extended("classify", args, acc), do: classify(args, acc)
  defp extended("remember", args, acc), do: remember(args, acc)
  defp extended(name, args, acc), do: outside(name, args, acc)

  defp outside("mcp", args, acc), do: mcp(args, acc)
  defp outside("search_tools", args, acc), do: search_tools(args, acc)
  defp outside(name, args, acc), do: runner(name, args, acc)

  # --- MCP tools -----------------------------------------------------------------------------

  # Only a tool the rules call safe (read-only, closed world) runs from a script; the policy's
  # network setting decides about an open-world one, as for `fetch`.
  defp mcp([server, name, args], acc) when is_binary(server) and is_binary(name) and is_map(args) do
    case Enum.find(acc.tools, &(&1.server == server and &1.name == name)) do
      nil -> {error("no MCP tool #{server}.#{name}; find tools with Script.search_tools(words)"), acc}
      tool -> mcp_tool(tool, args, acc)
    end
  end

  # --- decisions and objects -----------------------------------------------------------------

  defp mcp(_args, acc), do: {error("mcp takes a server name, a tool name and an arguments map"), acc}

  defp mcp_tool(tool, args, acc) do
    cond do
      refusal = Mcp.refusal(tool, acc.network) ->
        {error(refusal), acc}

      Tool.risk(tool) == :review ->
        {error(
           "not run: #{tool.server}.#{tool.name} would need a review (it is not a read-only, " <>
             "closed-world tool), and a script may run only tools that are safe by rule"
         ), acc}

      true ->
        child(acc, Effect.mcp(tool.server, tool.name, args, cwd: acc.cwd, risk: :safe))
    end
  end

  defp search_tools([query], acc) when is_binary(query) do
    found = for tool <- Tool.search(acc.tools, query), do: Map.take(tool, [:server, :name, :description, :schema])
    {Protocol.jsonable(found), acc}
  end

  defp search_tools(_args, acc), do: {error("search_tools takes a query"), acc}

  defp write([path, content], acc) when is_binary(path) and is_binary(content),
    do: changed(acc, path, Effect.write(path, content, cwd: acc.cwd))

  defp write(_args, acc), do: {error("write takes a path and the content"), acc}

  defp edit([path, old, new], acc) when is_binary(path) and is_binary(old) and is_binary(new),
    do: changed(acc, path, Effect.edit(path, old, new, cwd: acc.cwd))

  defp edit(_args, acc), do: {error("edit takes a path, the old text and the new"), acc}

  defp changed(acc, path, effect) do
    case Tools.refused(path, acc.cwd) do
      nil -> child(acc, effect)
      reason -> {error(reason), acc}
    end
  end

  defp decide([name, input], acc) when is_binary(name) and is_map(input) do
    case Enum.find(Decisions.all(), &(Decision.type!(&1).name == name)) do
      nil -> {error("unknown decision type #{inspect(name)}; the types are " <> type_names()), acc}
      module -> acc |> child(Effect.decide(module, input)) |> verdict()
    end
  end

  defp decide(_args, acc), do: {error("decide takes a type name and an input map"), acc}

  defp remember([id, attrs], acc) when is_binary(id) and is_map(attrs),
    do: child(acc, Effect.remember(id, Map.get(attrs, "type", "object"), Map.delete(attrs, "type")))

  defp remember(_args, acc), do: {error("remember takes an id and a map of attributes"), acc}

  defp type_names, do: Enum.map_join(Decisions.all(), ", ", &Decision.type!(&1).name)

  # One ad-hoc decision per question, in name order; the first bad question refuses the call.
  defp classify([questions, state], acc) when is_map(questions) and is_map(state) do
    case types(questions) do
      {:ok, types} ->
        input = %{"state" => JSON.encode!(state)}

        Enum.reduce(types, {%{}, acc}, fn {name, type}, {answers, acc} ->
          {answer, acc} = acc |> child(Effect.decide(type, input)) |> verdict()
          {Map.put(answers, name, answer), acc}
        end)

      {:error, reason} ->
        {error(reason), acc}
    end
  end

  defp classify(_args, acc), do: {error("classify takes a map of questions and a state map"), acc}

  # The question itself where the named questions go: the description's shape, read with "name" as a key.
  defp types(%{"type" => _}),
    do:
      {:error,
       ~s|classify takes named questions, %{"urgency" => %{"type" => "choice", ...}}; this is one | <>
         "question without a name: put it in a map under its name"}

  defp types(questions) do
    Enum.reduce_while(Enum.sort(questions), {:ok, []}, fn {name, question}, {:ok, types} ->
      case AdHoc.type(name, question) do
        {:ok, type} -> {:cont, {:ok, types ++ [{name, type}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # What a script needs of a decision: the value, how sure, who decided.
  defp verdict({%{"value" => value, "decision" => decision}, acc}) when is_map(decision) do
    {%{
       "value" => value,
       "confidence" => decision["confidence"],
       "actor" => decision["actor"],
       "model" => decision["model"],
       "probabilities" => decision["probabilities"] || %{}
     }, acc}
  end

  defp verdict(error_and_acc), do: error_and_acc

  # What only the runner has: the clock and randomness, as effects, so the log has what the script saw.
  defp runner("now", [], acc), do: acc |> child(Effect.now()) |> value()
  defp runner("random", [], acc), do: acc |> child(Effect.random()) |> value()
  defp runner(name, args, acc), do: {error("unknown call #{name}/#{length(args)}"), acc}

  defp value({%{"value" => value}, acc}), do: {value, acc}
  defp value(error_and_acc), do: error_and_acc

  defp bash(command, acc) do
    case Risk.assess(command, acc.cwd).verdict do
      :safe ->
        child(acc, Effect.bash(command, cwd: acc.cwd, timeout: remaining(acc)))

      :forbidden ->
        stop(acc, "`#{command}` is forbidden")

      nil ->
        {error(
           "not run: `#{command}` would need a review, and a script may run only commands " <>
             "that are safe by rule; run it as a bash tool call instead"
         ), acc}
    end
  end

  defp remaining(%{deadline: deadline}), do: max(deadline - System.monotonic_time(:millisecond), @min_command_ms)

  @interrupted "interrupted: Xeito stopped while this call was running, and did not run it again, " <>
                 "since running it twice could change something"

  # A call: fed from the log when the script is run again, else run as a child effect of the script's.
  defp child(acc, effect) do
    case Replay.feed(acc, effect) do
      {:logged, result, acc} ->
        {seen(result), acc}

      {:live, acc} ->
        live(acc, effect)

      {:interrupted, _id, acc} ->
        {error(@interrupted), acc}

      {:desync, logged} ->
        desync(acc, logged.id, "the log has #{Replay.describe(logged)}, the script asked for #{Replay.describe(effect)}")
    end
  end

  defp live(acc, effect) do
    case acc.child.(acc.effect.id, effect) do
      {:desync, id, reason} -> desync(acc, id, reason)
      result -> {seen(result), acc}
    end
  end

  defp desync(acc, id, reason), do: acc |> Map.put(:desync, id) |> stop("desync at #{id}: #{reason}")
  defp stop(acc, reason), do: {error("stopped: " <> reason), %{acc | stopped: reason}}

  # The result as the runner answers it: string keys, without the model's shaping and reference;
  # the script's API shapes it from there.
  defp seen(result), do: result |> Map.drop([:shaped, :ref]) |> Protocol.jsonable()

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
    do: failed(effect, "#{type}: #{message}" <> json_hint(message), output(failure[:stdio], acc.texts, nil))

  # A program written for another project reaches for Jason; Elixir's own JSON is there.
  defp json_hint(message) do
    if message =~ "Jason.",
      do: "\n(there is no Jason here: JSON is built in, JSON.decode!/1 and JSON.encode!/1)",
      else: ""
  end

  # What the script printed, its texts, then its last value, one per line; nothing for empties.
  defp output(stdio, texts, value) do
    [stdio | Enum.reverse(texts, [value])]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join("\n", &String.trim_trailing(&1, "\n"))
  end

  defp failed(_effect, reason, ""), do: %{ok: false, error: reason}
  defp failed(_effect, reason, so_far), do: %{ok: false, error: reason <> "\n\noutput so far:\n" <> so_far}
end
