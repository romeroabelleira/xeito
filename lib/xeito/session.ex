defmodule Xeito.Session do
  @moduledoc """
  One interactive session: a workspace, a conversation, and the runs started from it.

  For a free-form prompt the session

    1. decides `Xeito.Decisions.Intent` (an escalation child run, logged),
    2. selects a machine with `Xeito.Session.Router`,
    3. starts the run as `<session>/t<n>`, `part_of` the session in the log,
    4. forwards every event of that run and its children to the session topic, and
    5. when the run finishes, appends the turn to the history.

  - A run waiting in `ask_human` is answered with `approve/2` or `deny/1`; a scope
    (`"session"`, `"always"`) also remembers the command (`Xeito.Session.Allowed`).
  - A prompt typed while a turn runs is queued.
  - Step-mode settings (`/step`, `/break`, ...) apply to live and future runs; escalation runs never pause.
  - With no run and no activity for `:idle_timeout` (`config :xeito, :session_idle_timeout`,
    default 2 h) the session stops; its turns stay in the log and an id with logged turns is resumed.

  Events: `{:xeito, "session:<id>", %{type: type, run: run_id, attrs: map}}`, with the logged
  types plus `prompt`, `intent`, `run_selected`, `human_needed`, `turn_finished`, `notice`,
  `error` and the runs' `delta` stream.
  """

  use GenServer

  alias Xeito.Allowance
  alias Xeito.Budget
  alias Xeito.Chat.Window
  alias Xeito.Decisions.Intent
  alias Xeito.Escalation
  alias Xeito.Events
  alias Xeito.Log
  alias Xeito.Machines.Chat
  # --- client API ----------------------------------------------------------------------------
  alias Xeito.Machines.Check
  alias Xeito.Machines.Commit
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.RunTests
  alias Xeito.Machines.Shell
  alias Xeito.Policy
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.Session.Allowed
  alias Xeito.Session.ChatModel
  alias Xeito.Session.Git
  alias Xeito.Session.Router
  # --- server --------------------------------------------------------------------------------
  alias Xeito.Skills
  alias Xeito.Skills.Examples.Worker
  alias Xeito.Source.RepoMap
  alias Xeito.Tiers
  alias Xeito.Tools
  alias Xeito.Undo

  # Trimmed with slack (80 back to 60) so the first message, which keys the log's chain, rarely changes.
  @max_history 80
  @trimmed_history 60
  @agents_max_bytes 16_384

  @doc """
  Starts a session, or returns the id of the running one. Options: `:cwd` (required), `:id`,
  `:log` (default `Xeito.Log.for_workspace/1`), `:decider` (escalation options), `:chat`
  (chat-model overrides), `:max_steps`, `:test_cmd`, `:system` (replaces the system prompt),
  `:idle_timeout` (ms).
  """

  @spec start(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(opts) do
    id = Keyword.get_lazy(opts, :id, &new_id/0)
    spec = {__MODULE__, Keyword.put(opts, :id, id)}

    case DynamicSupervisor.start_child(Xeito.SessionSupervisor, spec) do
      {:ok, _pid} -> {:ok, id}
      {:error, {:already_started, _}} -> {:ok, id}
      error -> error
    end
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))

  @doc false
  def child_spec(opts), do: %{id: {__MODULE__, opts[:id]}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  # By group (command/3); `skill:` is a prefix.
  @start_commands ~w(machine run skill: steer)
  @turn_commands ~w(approve deny halt send drop)
  @info_commands ~w(why budget model help machines)
  @debug_commands ~w(step continue next decide break)
  @undo_commands ~w(undo redo)

  @doc "The slash commands the session takes, without the slash."
  @spec commands() :: [String.t()]
  def commands, do: @start_commands ++ @turn_commands ++ @info_commands ++ @debug_commands ++ @undo_commands

  @doc "Subscribes the caller to the session's events."
  @spec subscribe(String.t()) :: :ok
  def subscribe(id), do: Events.subscribe(topic(id))

  @doc "Submits a prompt or slash command; while a turn runs, a prompt is queued (see `/send`). Returns `:ok`."
  @spec prompt(String.t(), String.t()) :: :ok | {:error, term()}
  def prompt(id, text), do: GenServer.call(via(id), {:prompt, text})

  @doc """
  Approves the command a run is waiting on; with scope `"session"` or `"always"`, also remembers it.
  """
  @spec approve(String.t(), String.t() | nil) ::
          :ok
          | {:error, :nothing_to_approve | :not_accepted | :not_a_command | :unknown_scope | {:not_saved, File.posix()}}
  def approve(id, scope \\ nil)
  def approve(id, nil), do: GenServer.call(via(id), {:human, :approved})

  def approve(id, scope) when scope in ["session", "always"],
    do: GenServer.call(via(id), {:human, {:allow, scope(scope)}})

  def approve(_id, _scope), do: {:error, :unknown_scope}

  defp scope("session"), do: :session
  defp scope("always"), do: :always

  @doc "Denies the command a run is waiting on."
  @spec deny(String.t()) :: :ok | {:error, :nothing_to_approve}
  def deny(id), do: GenServer.call(via(id), {:human, :denied})

  @doc "The session's state: workspace, current run and machine, waiting prompt, history size."
  @spec status(String.t()) :: map()
  def status(id), do: GenServer.call(via(id), :status)

  @doc "The conversation history (messages without the system prompt)."
  @spec history(String.t()) :: [map()]
  def history(id), do: GenServer.call(via(id), :history)

  @doc """
  The workspace state for status bars, also emitted as a `workspace` event: git (`nil` outside a
  repository), off-box budget and chat tier.
  """
  @spec workspace(String.t()) :: map()
  def workspace(id), do: GenServer.call(via(id), :workspace)

  @doc "The session topic for `Xeito.Events`."
  @spec topic(String.t()) :: String.t()
  def topic(id), do: "session:" <> id

  defp via(id), do: {:via, Registry, {Xeito.SessionRegistry, id}}

  @impl true
  def init(opts) do
    cwd = opts |> Keyword.fetch!(:cwd) |> Path.expand()
    log = Keyword.get_lazy(opts, :log, fn -> Log.for_workspace(cwd) end)
    id = Keyword.fetch!(opts, :id)

    # So that a clean daemon stop runs terminate/2.
    Process.flag(:trap_exit, true)
    Log.put_object(log, id, "session", %{cwd: cwd, status: "open"})
    Events.subscribe(:all)

    state = %{
      id: id,
      cwd: cwd,
      log: log,
      decider: Keyword.get(opts, :decider, []),
      chat: Keyword.get(opts, :chat, []),
      max_steps: Keyword.get(opts, :max_steps),
      test_cmd: Keyword.get_lazy(opts, :test_cmd, fn -> Router.test_command(cwd) end),
      system: Keyword.get_lazy(opts, :system, fn -> system_prompt(cwd) end),
      history: [],
      # The last turn hit its step limit.
      unfinished: false,
      # Lines typed while a turn ran, oldest first; `held` after a turn that did not end normally.
      queue: [],
      held: false,
      stale_warned: false,
      decisions: [],
      debug: %{step: false, breakpoints: []},
      live: MapSet.new(),
      paused: nil,
      turn: 0,
      root: nil,
      machine: nil,
      prompt: nil,
      waiting: nil,
      allowed: Allowed.new(),
      idle_timeout:
        Keyword.get_lazy(opts, :idle_timeout, fn ->
          Application.get_env(:xeito, :session_idle_timeout, 7_200_000)
        end),
      active_at: now()
    }

    schedule_idle_check(state)
    {:ok, restore(state)}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp schedule_idle_check(s), do: Process.send_after(self(), :idle_check, max(div(s.idle_timeout, 4), 10))

  defp busy?(s), do: s.root != nil or s.waiting != nil or s.paused != nil

  # Rebuilds the history from logged turns; an unfinished run is reported, not re-executed.
  defp restore(s) do
    turns =
      s.log
      |> Log.query(
        "SELECT ocel_source_id FROM object_object WHERE ocel_target_id = ?1 AND ocel_qualifier = 'part_of'",
        [s.id]
      )
      |> Enum.flat_map(fn [run] ->
        case Regex.run(~r{/t(\d+)$}, run) do
          [_, n] -> [{String.to_integer(n), run}]
          nil -> []
        end
      end)
      |> Enum.sort()

    Enum.reduce(turns, s, &restore_turn/2)
  end

  defp restore_turn({n, run}, s) do
    s = %{s | turn: max(s.turn, n)}

    with [{_, "run_started", {:run_started, machine, _version, input}} | _] <-
           Log.read_run(s.log, run),
         {:ok, result} <- Run.result(s.log, run) do
      s = %{s | machine: machine, prompt: Map.get(input, :request) || Map.get(input, :prompt)}

      %{
        s
        | history: remember(s, result, answer(machine, result)),
          machine: nil,
          prompt: nil,
          unfinished: stopped?(result)
      }
    else
      _ ->
        %{
          s
          | history: s.history ++ [%{role: "assistant", content: "(turn #{n} was interrupted)"}]
        }
    end
  end

  # Every request counts as activity for the idle timeout.
  @impl true
  def handle_call(request, from, s), do: handle_request(request, from, %{s | active_at: now()})

  defp handle_request({:prompt, text}, _from, s) do
    {reply, s} = prompt(String.trim(text), text, warn_if_stale(s))
    {:reply, reply, s}
  end

  defp handle_request({:human, answer}, _from, s) do
    {reply, s} = human_answer(answer, s)
    {:reply, reply, s}
  end

  defp handle_request(:status, _from, s) do
    {:reply,
     %{
       id: s.id,
       cwd: s.cwd,
       run: s.root,
       machine: s.machine && inspect(s.machine),
       waiting: s.waiting,
       turns: s.turn,
       history: length(s.history),
       test_cmd: s.test_cmd
     }, s}
  end

  defp handle_request(:history, _from, s), do: {:reply, s.history, s}

  defp handle_request(:workspace, _from, s) do
    attrs = workspace_attrs(s)
    # --- prompts -------------------------------------------------------------------------------
    emit(s, "workspace", nil, attrs)
    {:reply, attrs, s}
  end

  # While a review waits, plain text is its answer: what to do instead of the call.
  defp prompt(trimmed, text, s) do
    log_prompt(trimmed, text, s)

    cond do
      Regex.match?(
        ~r{^/(approve|deny|halt|send|drop|steer|why|budget|model|help|machines|step|next|continue|break|decide)\b},
        trimmed
      ) ->
        "/" <> command = trimmed
        {:ok, command(command, s)}

      answers_review?(trimmed, s) ->
        {:ok, instruct(trimmed, s)}

      s.root != nil ->
        {:ok, enqueue(text, s)}

      true ->
        {:ok, start_turn(text, trimmed, s)}
    end
  end

  # Typed lines are logged for input history; lines clients send for keys are not.
  @key_lines ~w(/send /drop /halt /next /approve /deny)

  defp log_prompt(trimmed, _text, _s) when trimmed in ["" | @key_lines], do: :ok
  defp log_prompt("/approve " <> _scope, _text, _s), do: :ok
  defp log_prompt(_trimmed, text, s), do: log_event(s, "prompt_entered", %{"text" => text})

  defp answers_review?(trimmed, s), do: s.waiting != nil and trimmed != "" and not String.starts_with?(trimmed, "/")

  defp start_turn(text, trimmed, s) do
    s = %{s | turn: s.turn + 1, prompt: text}
    emit(s, "prompt", nil, %{"text" => text})

    case trimmed do
      "/" <> command -> command(command, s)
      _ -> route_prompt(text, trimmed, s)
    end
  end

  defp human_answer(_answer, %{waiting: nil} = s), do: {{:error, :nothing_to_approve}, s}
  defp human_answer({:allow, scope}, s), do: allow(scope, s)

  defp human_answer(answer, s) do
    case answer_human(s.waiting.run, answer) do
      :ok -> {:ok, %{s | waiting: nil}}
      :ignored -> {{:error, :not_accepted}, s}
    end
  end

  # An intent decided after its turn was halted (or for an earlier prompt) starts nothing.
  @impl true
  def handle_info({:intent, text, _decision}, %{root: root, prompt: prompt} = s) when root != :deciding or text != prompt,
    do: {:noreply, s}

  def handle_info({:intent, text, decision}, s), do: {:noreply, on_intent(text, decision, s)}
  def handle_info(:idle_check, s), do: idle_check(s)
  def handle_info({:xeito, run_id, event}, s) when is_binary(run_id), do: {:noreply, on_run_event(run_id, event, s)}

  def handle_info(_msg, s), do: {:noreply, s}

  defp on_intent(text, decision, s) do
    s = %{s | decisions: Enum.take([decision | s.decisions], 10)}

    cost = decision.cost || %{}

    emit(s, "intent", nil, %{
      "value" => decision.value,
      "confidence" => decision.confidence,
      "actor" => decision.actor,
      "tokens_in" => cost[:tokens_in],
      "tokens_out" => cost[:tokens_out],
      "usd" => cost[:usd],
      "joules_est" => cost[:joules_est],
      "latency_ms" => decision.latency_ms,
      "model" => decision.model
    })

    {machine, reason} = Router.route(decision.value, text)
    input = input_for(machine, text, s)

    # Only the rule's `other`: a model's `other` can be a reply to an unfinished turn.
    input = if small_talk?(machine, decision, s), do: Map.put(input, :tools, false), else: input
    start_machine(machine, input, reason, s)
  end

  defp small_talk?(machine, decision, s),
    do: machine == Chat and decision.value == :other and decision.actor == :rule and not s.unfinished

  defp idle_check(s) do
    if not busy?(s) and now() - s.active_at >= s.idle_timeout do
      emit(s, "closed", nil, %{"reason" => "idle", "idle_ms" => s.idle_timeout})
      {:stop, :normal, s}
    else
      schedule_idle_check(s)
      {:noreply, s}
    end
  end

  defp on_run_event(run_id, event, s) do
    if String.starts_with?(run_id, s.id <> "/") do
      emit(s, event.type, run_id, event.attrs)
      track(run_id, event, %{s | active_at: now()})
    else
      s
    end
  end

  # A crash records nothing; `Xeito.Log` marks the session `interrupted` on next open.
  @impl true
  def terminate(reason, s) when reason in [:normal, :shutdown] or (is_tuple(reason) and elem(reason, 0) == :shutdown) do
    Budget.delete(s.id)
    Log.put_object(s.log, s.id, "session", %{status: "closed"}, "status")
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, s), do: Budget.delete(s.id)

  # By rule: the Intent decision sees only the message and takes "go ahead" for small talk.
  @continuations ~r/\A(go ahead|go on|continue|carry on|proceed|keep going|yes|yes,? (please|do it|go ahead)|do it|please do|ok,? (go ahead|continue|do it))[\s.!]*\z/i

  defp route_prompt(text, trimmed, s),
    do: if(continuation?(trimmed, s), do: continue(text, s), else: decide_intent(text, s))

  defp continuation?(text, s), do: s.unfinished and Regex.match?(@continuations, text)

  defp continue(text, s) do
    decision = %Xeito.Decision{
      type: Intent,
      value: :edit,
      confidence: 1.0,
      actor: :rule,
      model: "rule:continuation",
      cost: %{}
    }

    send(self(), {:intent, text, decision})
    %{s | root: :deciding}
  end

  defp decide_intent(text, s) do
    me = self()
    id = "#{s.id}/t#{s.turn}/intent"

    opts =
      [log: s.log, parent: s.id, id: id] ++
        Keyword.take(s.decider, [:deciders, :policy, :tiers, :available?])

    Task.Supervisor.start_child(Xeito.EffectTasks, fn ->
      decision = Escalation.decide(Intent, %{message: text}, opts)
      send(me, {:intent, text, decision})
    end)

    %{s | root: :deciding}
  end

  defp command(command, s), do: command(String.split(command, ~r/\s+/, parts: 2) ++ [""], command, s)

  defp command([name, arg | _], raw, s) do
    case command_group(name) do
      :start -> start_command(name, arg, raw, s)
      :turn -> turn_command(name, arg, s)
      :info -> info_command(name, arg, s)
      :debug -> debug_command(name, arg, raw, s)
      :undo -> undo_command(name, arg, s)
      nil -> unknown_command(raw, s)
    end
  end

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

  defp command_group("skill:" <> _name), do: :start
  defp command_group(name), do: @command_groups[name]

  defp start_command("machine", rest, _raw, s), do: machine_command(rest, s)
  defp start_command("skill:" <> name, rest, _raw, s), do: skill_command(name, rest, s)
  defp start_command("run", "", _raw, s), do: error(s, "/run <command>: a shell command to run in the workspace")

  defp start_command("steer", "", _raw, s),
    do: error(s, "/steer <text>: a line for the running chat turn, taken at its next model call")

  defp start_command("steer", text, _raw, s), do: steer(text, s)
  defp start_command("run", cmd, _raw, s), do: start_machine(Shell, input_for(Shell, cmd, s), "/run", s)

  defp turn_command("approve", arg, s), do: approve_command(arg, s)
  defp turn_command("deny", _arg, s), do: human_command(:denied, s)
  defp turn_command("halt", _arg, s), do: halt(s)
  defp turn_command(send_or_drop, _arg, s), do: queue_command(send_or_drop, s)

  defp approve_command("", s), do: human_command(:approved, s)
  defp approve_command(scope, s) when scope in ["session", "always"], do: allow_command(scope(scope), s)
  defp approve_command(arg, s), do: error(s, "/approve takes session or always, not #{inspect(arg)}")

  defp allow_command(scope, s) do
    case human_answer({:allow, scope}, s) do
      {:ok, s} -> s
      {{:error, reason}, s} -> error(s, allow_error(reason))
    end
  end

  @allow_errors %{
    nothing_to_approve: "nothing is waiting for approval",
    not_a_command: "only a shell command can be allowed; /approve answers this review",
    not_accepted: "the waiting run did not accept approved"
  }

  defp allow_error({:not_saved, reason}), do: "approved, but .xeito/allowed.json could not be written: #{inspect(reason)}"
  defp allow_error(reason), do: Map.fetch!(@allow_errors, reason)

  defp queue_command(_send_or_drop, %{queue: []} = s), do: error(s, "nothing is queued")

  defp queue_command("send", %{root: root} = s) when root != nil,
    do: error(s, "a turn is running; queued lines are sent when it ends")

  defp queue_command("send", s), do: send_queued(s)
  defp queue_command("drop", s), do: dequeue(s, "dropped")

  defp info_command("why", _arg, s), do: why(s)
  defp info_command("budget", usd, s), do: budget(usd, s)
  defp info_command("model", name, s), do: chat_model(name, s)
  defp info_command("help", _arg, s), do: notice(s, help())
  defp info_command("machines", _arg, s), do: notice(s, machines_text(s))

  defp debug_command("step", _arg, _raw, s), do: set_debug(%{s.debug | step: not s.debug.step}, s)
  defp debug_command("continue", _arg, _raw, s), do: set_debug(%{s.debug | step: false}, s)
  defp debug_command("next", _arg, _raw, s), do: step(:next, s)
  defp debug_command(name, arg, raw, s), do: debug_arg_command(name, arg, raw, s)

  defp debug_arg_command(_name, "", raw, s), do: unknown_command(raw, s)
  defp debug_arg_command("decide", value, _raw, s), do: step({:decide, value}, s)
  defp debug_arg_command("break", "clear", _raw, s), do: set_debug(%{s.debug | breakpoints: []}, s)
  defp debug_arg_command("break", spec, _raw, s), do: add_breakpoint(spec, s)

  # The model is told, so it does not assume the files are as it left them.
  defp undo_command(name, arg, s) do
    case count(arg) do
      {:ok, n} -> name |> undo_or_redo(s, n) |> undone(name, s)
      :error -> error(s, "/#{name} [n]: n steps, 1 or more (/#{name} alone is one)")
    end
  end

  defp count(""), do: {:ok, 1}

  defp count(arg) do
    case Integer.parse(arg) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp undo_or_redo("undo", s, n), do: Undo.undo(s.cwd, s.id, n)
  defp undo_or_redo("redo", s, n), do: Undo.redo(s.cwd, s.id, n)

  defp undone({:ok, steps}, name, s) do
    log_undone(steps, name, s)
    labels = Enum.map(steps, & &1.label)
    s = %{s | history: s.history ++ [%{role: "user", content: undo_note(name, labels)}]}
    details = branch_moved(steps, name) <> outside(steps) <> not_covered(steps)
    notice(s, undo_notice(name, labels) <> Enum.map_join(labels, &"  #{&1}\n") <> details)
  end

  defp undone({:error, reason}, name, s), do: error(s, undo_error(reason, name))

  # Logged in the session's own stream, not a run's, against the effect reverted.
  defp log_undone(steps, name, s) do
    {type, qualifier} = if name == "undo", do: {"step_undone", "undoes"}, else: {"step_redone", "redoes"}
    Log.append(s.log, s.id, Enum.map(steps, &undo_event(&1, type, qualifier)))
  end

  defp undo_event(step, type, qualifier) do
    attrs = %{"effect_id" => step.id, "label" => step.label}
    Log.Event.new(type, {String.to_atom(type), step.id, step.label}, attrs, [{step.id, "effect", qualifier}])
  end

  defp branch_moved(steps, name) do
    case Enum.filter(steps, &is_map(&1.git)) do
      [] ->
        ""

      commits ->
        last = List.last(commits)
        {way, commit} = if name == "undo", do: {"back", last.git.from}, else: {"forward", last.git.to}
        "#{String.replace_prefix(last.git.ref, "refs/heads/", "")}: #{way} to #{String.slice(commit, 0, 7)}\n"
    end
  end

  defp outside(steps) do
    case Enum.flat_map(steps, & &1.outside) do
      [] -> ""
      paths -> "outside the workspace: #{paths |> Enum.uniq() |> Enum.join(", ")}\n"
    end
  end

  defp not_covered(steps) do
    case Enum.flat_map(steps, & &1.skipped) do
      [] -> ""
      files -> "not covered (over 5 MB, left as they are): #{files |> Enum.uniq() |> Enum.join(", ")}\n"
    end
  end

  defp undo_notice("undo", labels), do: "undid #{steps(labels)} (/redo reverses this):\n"
  defp undo_notice("redo", labels), do: "redid #{steps(labels)}:\n"

  defp undo_note("undo", labels),
    do: "(I undid #{length(labels)} of your steps: #{Enum.join(labels, "; ")}. Those files are as they were before them.)"

  defp undo_note("redo", labels),
    do: "(I redid #{length(labels)} of your steps that I had undone: #{Enum.join(labels, "; ")}.)"

  defp steps(labels), do: plural(length(labels))
  defp plural(1), do: "1 step"
  defp plural(n), do: "#{n} steps"

  defp undo_error({:only, n}, name), do: "only #{plural(n)} to #{name}; nothing was #{name}ne"

  defp undo_error({:conflict, step}, name),
    do: "can't #{name} #{step.label}: those lines changed since; nothing was #{name}ne"

  defp undo_error({cause, step, detail}, name), do: "can't #{name} #{step.label}: " <> step_error(cause, detail, name)
  defp undo_error(nothing, name) when nothing in [:nothing_to_undo, :nothing_to_redo], do: "nothing to #{name}"

  defp undo_error(_unavailable_or_changed, name),
    do: "can't #{name} now: no snapshot of the workspace (no git, or too many files), or it changed meanwhile"

  defp step_error(:outside_changed, path, name), do: "#{path} changed since; nothing was #{name}ne"
  defp step_error(:git, reason, name), do: git_error(reason, name)

  defp git_error({:pushed, commit}, _name) do
    short = String.slice(commit, 0, 7)
    "commit #{short} is already pushed; to reverse it, run: git revert #{short}"
  end

  defp git_error(:moved, name), do: "it moved HEAD (checkout, reset or rebase); #{name} that with git"
  defp git_error(:branch_moved, name), do: "its branch has moved since; nothing was #{name}ne"

  defp unknown_command(raw, s), do: error(s, "unknown command /#{raw}; try /help")

  defp machine_command(rest, s) do
    [name | prompt] = String.split(rest, ~r/\s+/, parts: 2) ++ [""]

    case Router.machines() do
      %{^name => machine} ->
        start_machine(machine, input_for(machine, Enum.join(prompt), s), "/machine", s)

      machines ->
        error(
          s,
          "unknown machine #{inspect(name)}; available: #{Enum.join(Map.keys(machines), ", ")}"
        )
    end
  end

  # `/skill:name args`: the skill's instructions become the prompt of a chat turn.
  defp skill_command(name, request, s) do
    case Enum.find(Skills.discover(s.cwd), &(&1.name == name)) do
      nil ->
        error(s, "no skill named #{inspect(name)}")

      skill ->
        prompt = """
        Use the skill "#{skill.name}". Its directory is #{skill.dir}; paths in it are relative to
        that directory, and the skill tool reads its files. Instructions:

        #{Skills.body(skill)}

        Request: #{if request == "", do: "(none; follow the instructions)", else: request}
        """

        start_machine(Chat, Map.put(input_for(Chat, prompt, s), :skill_candidates, []), "/skill:#{name}", s)
    end
  end

  @halted "Halted by the user."

  # Once per session.
  defp warn_if_stale(%{stale_warned: true} = s), do: s

  defp warn_if_stale(s) do
    if Xeito.Preload.stale?(),
      do:
        notice(
          %{s | stale_warned: true},
          "· the daemon's code changed on disk since it started (a rebuild or a dependency update), " <>
            "and it keeps running the code it loaded then: restart it to use the new code " <>
            "(systemctl --user restart xeitod, or stop and start mix xeito.daemon)"
        ),
      else: s
  end

  # Stops the run and the runs under it, or the intent decision before any run started.
  defp halt(%{root: nil} = s), do: error(s, "nothing is running")

  defp halt(%{root: :deciding} = s) do
    emit(s, "turn_finished", nil, %{"status" => :halted, "final_state" => :intent, "answer" => @halted})
    hold(%{s | root: nil}, "halted")
  end

  defp halt(s) do
    case Run.halt(s.root) do
      :ok -> s
      {:error, :not_running} -> error(s, "nothing is running")
    end
  end

  defp instruct(text, s) do
    case Run.send_event(s.waiting.run, :instructed, %{text: text}, :human) do
      {:ok, _leaf} -> %{s | waiting: nil}
      :ignored -> error(s, "this review takes y or n only (/approve, /deny)")
    end
  catch
    :exit, _ -> error(s, "the waiting run is gone")
  end

  defp human_command(answer, %{waiting: nil} = s), do: error(s, "nothing is waiting for #{answer}")

  defp human_command(answer, s) do
    case answer_human(s.waiting.run, answer) do
      :ok -> %{s | waiting: nil}
      :ignored -> error(s, "the waiting run did not accept #{answer}")
    end
  end

  # Only a shell command can be allowed.
  defp allow(scope, %{waiting: %{run: run, call: call}} = s) do
    with {:ok, command} <- Allowed.command(call),
         :ok <- answer_human(run, :approved) do
      keep_allowed(scope, command, %{s | waiting: nil})
    else
      :error -> {{:error, :not_a_command}, s}
      :ignored -> {{:error, :not_accepted}, s}
    end
  end

  # Approved already; only the write to `.xeito/allowed.json` can fail here.
  defp keep_allowed(scope, command, s) do
    case Allowed.remember(scope, command, s.cwd, s.allowed) do
      {:ok, allowed} -> {:ok, notice(%{s | allowed: allowed}, "approved · `#{command}` is now #{allowed_how(scope)}")}
      {:error, reason} -> {{:error, {:not_saved, reason}}, s}
    end
  end

  defp allowed_how(:session), do: "allowed for this session"
  defp allowed_how(:always), do: "always allowed in this workspace (.xeito/allowed.json)"

  # Fallback for a machine's own ask_human state, which takes :answered / :abort (fix_failing_test).
  @fallback %{approved: :answered, denied: :abort}

  defp answer_human(run, answer, data \\ %{}) do
    # --- run tracking --------------------------------------------------------------------------
    with :ignored <- Run.send_event(run, answer, data, :human),
         :ignored <- Run.send_event(run, @fallback[answer], data, :human) do
      :ignored
    else
      {:ok, _leaf} -> :ok
    end
  catch
    :exit, _ -> :ignored
  end

  # --- step mode -----------------------------------------------------------------------------
  # Skills are discovered every turn, so an edited SKILL.md applies at once.
  defp input_for(Chat, text, s), do: chat_input(text, s)

  defp input_for(Commit, text, s), do: %{cwd: s.cwd, request: text}

  defp input_for(Check, _text, s), do: %{cwd: s.cwd, check_cmd: Router.check_command(s.cwd), system: s.system}

  defp input_for(FixFailingTest, _text, s), do: %{cwd: s.cwd, test_cmd: s.test_cmd, delegate: true, system: s.system}

  defp input_for(RunTests, _text, s), do: %{cwd: s.cwd, test_cmd: s.test_cmd}

  defp input_for(Shell, cmd, s), do: %{cwd: s.cwd, cmd: cmd}

  defp chat_input(text, s) do
    skills = Skills.discover(s.cwd)
    # Outside the daemon there is no worker and the cast goes nowhere.
    Worker.wanted(skills)
    %{listed: listed, candidates: candidates} = Skills.for_turn(skills, s.cwd, text)

    then(
      %{
        cwd: s.cwd,
        prompt: text,
        messages: s.history,
        verify: Router.quick_check_command(s.cwd),
        system: s.system <> repo_map(s.cwd) <> Skills.prompt_section(listed),
        context: ChatModel.context(ChatModel.current(s.chat), chat_config(s)),
        skills: Enum.map(skills, &Map.take(&1, [:name, :dir])),
        skill_candidates: Enum.map(candidates, &Map.take(&1, [:name, :description]))
      },
      &if(s.max_steps, do: Map.put(&1, :max_steps, s.max_steps), else: &1)
    )
  end

  defp repo_map(cwd) do
    case RepoMap.build(cwd) do
      nil -> ""
      map -> "\n\n" <> map <> "\n"
    end
  end

  defp start_machine(machine, input, reason, s) do
    run_id = "#{s.id}/t#{s.turn}"
    runner = {Xeito.Effects.Local, decider: s.decider, chat: s.chat}

    emit(s, "run_selected", run_id, %{"machine" => inspect(machine), "reason" => reason})

    start = [run_id: run_id, log: s.log, runner: runner, debug: s.debug]

    # Kept in the input so a resumed session can rebuild its history.
    input = Map.put_new(input, :request, s.prompt)

    case RunSupervisor.start_run(machine, input, start) do
      {:ok, ^run_id} ->
        Log.relate(s.log, run_id, s.id, "part_of")
        %{s | root: run_id, machine: machine}

      {:error, reason} ->
        error(%{s | root: nil}, "could not start #{inspect(machine)}: #{inspect(reason)}")
    end
  end

  defp track(run_id, %{type: "state_entered", attrs: %{"state" => :ask_human}}, s) do
    call = pending_call(run_id)

    case Allowed.scope(s.cwd, s.allowed, call) do
      nil -> wait_for_human(run_id, call, s)
      scope -> skip_review(run_id, call, scope, s)
    end
  end

  defp track(run_id, %{type: "state_exited", attrs: %{"state" => :ask_human}}, s), do: review_ended(run_id, s)

  defp track(run_id, %{type: "run_finished"} = event, %{root: run_id} = s) do
    {:ok, result} = Run.result(s.log, run_id)
    answer = answer(s.machine, result)
    # Before `turn_finished`, so that it is the turn's last event and no git runs after it.
    emit(s, "workspace", nil, workspace_attrs(%{s | root: nil}))
    emit(s, "turn_finished", run_id, Map.put(event.attrs, "answer", answer))

    s = %{s | root: nil, machine: nil, waiting: nil, history: remember(s, result, answer), unfinished: stopped?(result)}
    s |> requeue_steers(result) |> warn_truncated(result) |> after_turn(result, answer)
  end

  defp track(run_id, event, s), do: track_run(run_id, event, s)

  defp wait_for_human(run_id, call, s) do
    emit(s, "human_needed", run_id, %{"call" => call})
    %{s | waiting: %{run: run_id, call: call}}
  end

  # Allowed before: approved as the human would, with the scope in the log.
  defp skip_review(run_id, call, scope, s) do
    {:ok, command} = Allowed.command(call)

    case answer_human(run_id, :approved, %{allowed: scope}) do
      :ok -> notice(s, "· `#{command}` runs without asking: #{allowed_how(scope)}")
      :ignored -> wait_for_human(run_id, call, s)
    end
  end

  # --- input while busy ---

  # Idle, a steer is a prompt; during a machine other than chat, it is queued.
  defp steer(text, %{root: nil} = s), do: start_turn(text, String.trim(text), s)

  defp steer(text, %{machine: Chat, root: run} = s) when is_binary(run) do
    case Run.send_event(run, :steered, %{text: text}, :human) do
      {:ok, _leaf} ->
        emit(s, "steered", run, %{"text" => text})
        s

      _not_taken ->
        enqueue(text, s)
    end
  end

  defp steer(text, s), do: s |> notice("steering reaches a chat turn only; queued instead") |> then(&enqueue(text, &1))

  # Steers the turn ended before delivering are queued.
  defp requeue_steers(s, result), do: result.ctx |> Chat.undelivered() |> Enum.reduce(s, &enqueue/2)

  # A queued line is never taken as a review's answer.
  defp enqueue(text, s) do
    queue = s.queue ++ [text]
    emit(s, "queued", nil, %{"text" => text, "queued" => length(queue)})
    log_event(s, "prompt_queued", %{"text" => text})
    %{s | queue: queue}
  end

  # A normal ending sends the first queued line; otherwise the queue is held.
  defp after_turn(%{queue: []} = s, _result, _answer), do: s
  defp after_turn(%{held: true} = s, _result, _answer), do: s

  defp after_turn(s, result, answer),
    do: if(release?(result, answer), do: send_queued(s), else: hold(s, hold_reason(result)))

  @doc false
  # Done, not stopped at its step limit, and not asking a question.
  def release?(result, answer),
    do:
      result.status == :done and not stopped?(result) and
        not (answer |> to_string() |> String.trim() |> String.ends_with?("?"))

  defp hold_reason(%{status: status}) when status in [:halted, :failed], do: to_string(status)
  defp hold_reason(%{ctx: %{stopped: true}}), do: "stopped"
  defp hold_reason(_result), do: "question"

  defp hold(%{queue: []} = s, _reason), do: s

  defp hold(s, reason) do
    emit(s, "queue_held", nil, %{"reason" => reason, "queued" => length(s.queue)})
    %{s | held: true}
  end

  defp send_queued(s) do
    text = hd(s.queue)
    s = dequeue(s, "sent")
    {_reply, s} = prompt(String.trim(text), text, s)
    s
  end

  defp dequeue(%{queue: [text | rest]} = s, outcome) do
    emit(s, "dequeued", nil, %{"text" => text, "outcome" => outcome})
    log_event(s, "prompt_dequeued", %{"text" => text, "outcome" => outcome})
    %{s | queue: rest, held: s.held and rest != []}
  end

  defp log_event(s, type, attrs), do: Log.append(s.log, s.id, [Log.Event.new(type, {String.to_atom(type), attrs}, attrs)])

  defp review_ended(run_id, s), do: if(s.waiting && s.waiting.run == run_id, do: %{s | waiting: nil}, else: s)

  defp track_run(run_id, %{type: "paused"}, s), do: %{s | paused: run_id}

  defp track_run(run_id, %{type: "run_started"}, s) do
    if internal?(run_id), do: s, else: %{s | live: MapSet.put(s.live, run_id)}
  end

  defp track_run(run_id, %{type: "run_finished"}, s),
    do: %{s | live: MapSet.delete(s.live, run_id), paused: unpause(s.paused, run_id)}

  # Streamed pieces can arrive after the run paused: they do not mean it moved on.
  defp track_run(run_id, %{type: type}, s) when type not in ~w(delta output), do: %{s | paused: unpause(s.paused, run_id)}
  defp track_run(_run_id, _event, s), do: s

  defp stopped?(%{status: :halted}), do: true
  defp stopped?(%{ctx: ctx}), do: Map.get(ctx, :stopped, false) == true
  defp stopped?(_result), do: false

  defp unpause(run_id, run_id), do: nil
  defp unpause(paused, _run_id), do: paused

  defp workspace_attrs(s) do
    policy = Policy.effective(Keyword.take(s.decider, [:policy]))
    tier = ChatModel.current(s.chat)
    spent = if is_binary(s.root), do: Budget.get(s.root, :usd), else: 0

    %{
      "missing" => not File.dir?(s.cwd),
      "git" => Git.status(s.cwd),
      "budget" => %{
        "off_box" => (policy.remote == :allowed and policy.locality == :public) or ChatModel.off_box?(tier),
        "max_usd_per_run" => policy.max_usd_per_run,
        "spent_usd" => spent
      },
      "chat" => chat_attrs(tier, chat_config(s))
    }
  end

  # `Allowance.last/1` makes no request.
  defp chat_attrs(tier, cfg) do
    left = if ChatModel.off_box?(tier) and cfg[:url], do: Allowance.last(cfg)
    %{"tier" => tier, "model" => cfg[:model], "off_box" => ChatModel.off_box?(tier), "left_usd" => left}
  end

  defp internal?(run_id), do: String.ends_with?(run_id, "/esc") or String.ends_with?(run_id, "/intent")

  defp set_debug(debug, s) do
    Enum.each(s.live, &debug_run(&1, debug))
    notice(%{s | debug: debug}, debug_text(debug))
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

  defp step(_how, %{paused: nil} = s), do: error(s, "no run is paused")

  defp step({:decide, value}, s) do
    case existing_atom(value) do
      {:ok, atom} -> step({:decide_atom, atom}, s)
      :error -> error(s, "cannot step: invalid_value")
    end
  end

  defp step(how, s) do
    how = with {:decide_atom, atom} <- how, do: {:decide, atom}

    case Run.step(s.paused, how) do
      :ok -> %{s | paused: nil}
      {:error, reason} -> error(s, "cannot step: #{reason}")
    end
  end

  # User input never creates atoms: decision values and state names already exist.
  defp existing_atom(text) do
    {:ok, String.to_existing_atom(text)}
  rescue
    ArgumentError -> :error
  end

  defp add_breakpoint(spec, s) do
    case parse_breakpoint(spec) do
      {:ok, bp} -> set_debug(%{s.debug | breakpoints: Enum.uniq(s.debug.breakpoints ++ [bp])}, s)
      :error -> error(s, "breakpoints: state:<name>, decision:<Type>, conf<0.6, clear")
    end
  end

  @doc false
  def parse_breakpoint("state:" <> name) do
    with {:ok, state} <- existing_atom(name), do: {:ok, {:state, state}}
  end

  def parse_breakpoint("decision:" <> name), do: decision_breakpoint(Module.concat(Xeito.Decisions, Macro.camelize(name)))
  def parse_breakpoint("conf<" <> x), do: x |> Float.parse() |> confidence_breakpoint()

  def parse_breakpoint(_spec), do: :error

  defp decision_breakpoint(module), do: if(Code.ensure_loaded?(module), do: {:ok, {:decision, module}}, else: :error)

  defp confidence_breakpoint({f, ""}), do: {:ok, {:confidence_below, f}}
  defp confidence_breakpoint(_parsed), do: :error

  # The timeout the command will actually get, not what the model asked.
  defp runs_for(%{"tool" => "bash", "arguments" => %{"timeout_s" => asked}} = call),
    do: Map.put(call, "runs_for_s", div(Tools.bash_timeout_ms(asked), 1_000))

  defp runs_for(call), do: call

  defp pending_call(run_id) do
    case Run.whereis(run_id) && Run.snapshot(run_id) do
      %{ctx: %{current: %{name: name, arguments: args}}} -> runs_for(%{"tool" => name, "arguments" => args})
      %{ctx: %{review: summary}} -> %{"tool" => "review", "summary" => summary}
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc false
  def turn_answer(machine, result), do: answer(machine, result)

  defp answer(_machine, %{status: :halted}), do: @halted
  defp answer(Chat, %{ctx: ctx}), do: Map.get(ctx, :answer) || ctx |> Map.get(:error) |> to_text()

  defp answer(FixFailingTest, result), do: fix_failing_answer(result)
  defp answer(Shell, %{ctx: %{cmd: cmd, exit_status: status}}), do: "`#{cmd}` exited #{status}"

  defp answer(machine, result), do: ended(machine, result)

  defp ended(machine, %{state: state} = result) do
    ctx = Map.get(result, :ctx, %{})

    Map.get(ctx, :answer) ||
      ctx |> Map.get(:error) |> to_text() |> default("#{inspect(machine)} ended in #{state}")
  end

  defp fix_failing_answer(%{state: :done, ctx: ctx}) when not is_map_key(ctx, :last_failure),
    do:
      "The tests pass (#{Map.get(ctx, :test_cmd, "the test suite")}): there is no failing test to fix. " <>
        "To write a new test, ask for it without saying it fails, or use /machine chat <request>."

  defp fix_failing_answer(%{state: state, ctx: ctx}), do: "fix_failing_test ended in #{state}" <> fix_answer(ctx)

  defp fix_answer(ctx) do
    case get_in(ctx, [:fix, :answer]) do
      nil -> ""
      fix -> ": " <> fix
    end
  end

  defp default("", fallback), do: fallback
  defp default(text, _fallback), do: text

  defp to_text(nil), do: ""
  defp to_text(text) when is_binary(text), do: text
  # Reasons from `Xeito.Allowance` are written for the user.
  defp to_text({:budget, text}), do: text
  defp to_text({:allowance, text}), do: text
  defp to_text(other), do: inspect(other)

  defp warn_truncated(s, %{ctx: %{context_truncated: true}}),
    do:
      notice(
        s,
        "the model server cut this turn's prompt from the front (the system prompt was lost): " <>
          "set XEITO_LOCAL_CONTEXT to the model's context window"
      )

  defp warn_truncated(s, _result), do: s

  defp chat_config(s), do: Tiers.config(ChatModel.current(s.chat)) || []

  defp chat_model("", s) do
    cfg = chat_config(s)
    notice(s, ChatModel.describe(ChatModel.current(s.chat), chat_configs(), cfg[:url] && Allowance.last(cfg)))
  end

  defp chat_model(name, s) do
    case ChatModel.choose(name, chat_configs()) do
      {:ok, tier} ->
        s = %{s | chat: Keyword.put(s.chat, :tier, tier)}
        emit(s, "workspace", nil, workspace_attrs(%{s | root: nil}))

        notice(
          s,
          ChatModel.switched(tier, chat_config(s), Policy.effective(Keyword.take(s.decider, [:policy])).max_usd_per_run)
        )

      {:error, text} ->
        error(s, text)
    end
  end

  defp chat_configs, do: Map.new(ChatModel.tiers(), &{&1, Tiers.config(&1)})

  defp remember(%{machine: Chat}, %{status: :halted, ctx: %{turn: [_system | messages]}}, answer),
    do: trim_history(settled(messages) ++ [%{role: "assistant", content: "(#{answer})"}])

  defp remember(%{machine: Chat}, %{ctx: %{turn: [_system | messages]}}, _answer), do: trim_history(messages)

  # A note in the user's voice, not an exchange.
  defp remember(%{machine: Shell} = s, %{ctx: ctx}, _answer),
    do: trim_history(s.history ++ [%{role: "user", content: shell_note(ctx)}])

  defp remember(s, _result, answer) do
    trim_history(s.history ++ [%{role: "user", content: s.prompt || ""}, %{role: "assistant", content: answer}])
  end

  defp shell_note(%{cmd: cmd, report: report}), do: "(I ran `#{cmd}` in the workspace:\n```\n#{report}\n```)"
  defp shell_note(%{cmd: cmd}), do: "(I ran `#{cmd}` in the workspace and stopped it before it finished.)"

  @doc false
  # Drops a trailing tool call left unanswered, so the next request is well-formed.
  def settled(messages) do
    with i when i != nil <- Enum.find_index(Enum.reverse(messages), &calls?/1),
         {before, [call | rest]} <- Enum.split(messages, length(messages) - 1 - i),
         true <- Enum.count(rest, &(&1.role == "tool")) < length(call.tool_calls) do
      before
    else
      _ -> messages
    end
  end

  defp calls?(message), do: match?(%{role: "assistant", tool_calls: [_ | _]}, message)

  # A leading summary of earlier turns stays first.
  @doc false
  def trim_history(messages) when length(messages) > @max_history do
    {pinned, rest} = Enum.split_while(messages, &Window.summary?/1)
    pinned ++ Enum.take(rest, length(pinned) - @trimmed_history)
  end

  def trim_history(messages), do: messages

  # --- commands ------------------------------------------------------------------------------

  defp why(s) do
    own =
      for d <- s.decisions do
        [inspect(d.type), d.value, d.confidence, d.actor, d.model, d.latency_ms]
      end

    rows =
      Log.query(
        s.log,
        "SELECT d.decision_type, d.value, d.confidence, d.actor, d.model, d.latency_ms " <>
          "FROM event_decision_made d JOIN xeito_term t ON t.ocel_id = d.ocel_id " <>
          "WHERE t.run_id LIKE ?1 ORDER BY t.rowid DESC LIMIT 10",
        [s.id <> "/%"]
      )

    # --- context -------------------------------------------------------------------------------
    lines =
      for [type, value, conf, actor, model, ms] <- own ++ rows do
        "#{String.replace_prefix(type, "Xeito.Decisions.", "")}: #{value} by #{actor} " <>
          "(#{format_conf(conf)}, #{model}, #{ms} ms)"
      end

    notice(s, if(lines == [], do: "no decisions yet", else: Enum.join(lines, "\n")))
  end

  defp format_conf(nil), do: "-"
  defp format_conf(c) when is_number(c), do: :erlang.float_to_binary(c * 1.0, decimals: 2)

  # Attributes read back from the log are text.
  defp format_conf(c) when is_binary(c) do
    case Float.parse(c) do
      {f, _} -> format_conf(f)
      :error -> c
    end
  end

  defp budget(usd, s) do
    case Float.parse(usd) do
      {value, _} when value >= 0 ->
        policy = Keyword.put(Keyword.get(s.decider, :policy, []), :max_usd_per_run, value)
        s = %{s | decider: Keyword.put(s.decider, :policy, policy)}
        notice(s, "off-box budget per run: $#{value}")

      _ ->
        error(s, "usage: /budget <usd>")
    end
  end

  defp machines_text(s) do
    rows = Router.describe(s.cwd, s.log)

    header =
      String.pad_trailing("machine", 18) <>
        String.pad_trailing("version", 9) <> "runs  done  failed  last run (UTC)"

    lines =
      for m <- rows do
        u = m.usage

        last =
          if u.last,
            do: u.last |> to_string() |> String.slice(0, 16) |> String.replace("T", " "),
            else: "-"

        String.pad_trailing(m.name, 18) <>
          String.pad_trailing(m.version, 9) <>
          String.pad_trailing("#{u.runs}", 6) <>
          String.pad_trailing("#{u.done}", 6) <>
          String.pad_trailing("#{u.failed}", 8) <>
          last <> "\n    #{m.summary}\n    routed from: #{m.routed_from} · /machine #{m.name}"
      end

    Enum.join([header | lines], "\n")
  end

  defp help do
    """
    /help                     this list
    /machines                 list the machines: what they do, how they are routed, usage
    /machine <name> [prompt]  start a machine directly (#{Enum.join(Map.keys(Router.machines()), ", ")})
    /skill:<name> [request]   run a skill (pi / Agent Skills format)
    /run <command>            run a shell command in the workspace, without a model or review;
                              its output joins the conversation for the next turn
    /approve · /deny          answer a command waiting for review (or type what to do instead)
    /approve session|always   approve it and do not ask about this exact command again: for the
                              rest of this session, or ever in this workspace (.xeito/allowed.json)
    /undo [n] · /redo [n]     revert this session's last n file changes, or put them back
    /steer <text>             a line for the running chat turn, taken at its next model call
                              (Ctrl-J in the TUI); idle, a prompt
    /send · /drop             send the first line typed while a turn ran, or drop it (held when
                              the turn ended halted, failed, stopped, or with a question)
    /halt                     stop the turn where it is (Esc in the TUI); "go ahead" continues it
    /why                      the last decisions, with tier and confidence
    /budget <usd>             off-box spend limit per run (a remote chat turn included)
    /model [tier]             the chat tiers; switch this session's chat (local, remote, remote_frontier)
    /quit                     close the client (the session keeps running; attach with --session)
    /statusbar …              TUI only: on|off|reset|segments|show|hide <segment>
    /legend                   TUI only: what the coloured dots beside commands mean
    /sessions [N|new]         TUI only: this directory's sessions; switch to one, or start another
    /step · /next · /continue step mode: pause before each result, release one, run on
    /decide <value>           answer a paused decision yourself (logged as a label)
    /break state:<s> | decision:<Type> | conf<0.6 | clear
    """
  end

  defp notice(s, text) do
    emit(s, "notice", nil, %{"text" => text})
    s
  end

  defp error(s, text) do
    emit(s, "error", nil, %{"text" => text})
    s
  end

  defp emit(s, type, run, attrs), do: Events.notify(topic(s.id), %{type: type, run: run, attrs: attrs})

  @doc false
  def system_prompt(cwd) do
    case File.read(Path.join(cwd, "AGENTS.md")) do
      {:ok, text} ->
        Chat.default_system() <> "\nProject context (AGENTS.md):\n\n" <> agents_text(text)

      {:error, _} ->
        Chat.default_system()
    end
  end

  defp agents_text(text) when byte_size(text) <= @agents_max_bytes, do: text

  defp agents_text(text),
    do:
      binary_part(text, 0, @agents_max_bytes) <>
        "\n\n[AGENTS.md continues: cut at #{@agents_max_bytes} bytes here. Read the file for the rest.]"

  defp new_id, do: "ses-" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
end
