defmodule Xeito.Session do
  @moduledoc """
  One interactive session: a workspace, a conversation, and the runs started from it. Clients
  (TUI, CLI, bridge) talk to a session; the session talks to machines.

  For a free-form prompt the session

    1. decides `Xeito.Decisions.Intent` (an escalation child run, logged),
    2. selects a machine with `Xeito.Session.Router` (rules),
    3. starts the run as `<session>/t<n>`, related `part_of` the session in the log,
    4. forwards every event of that run and its children to the session topic, and
    5. when the run finishes, appends the turn to the conversation history.

  A run waiting in an `ask_human` state (for example a `bash` call the `Risk` decision sent to
  review) is answered with `approve/1` or `deny/1`.

  Slash commands: `/machine <name> [prompt]`, `/run <command>`, `/approve`, `/deny`, `/why`,
  `/budget <usd>`, `/help`, and for step mode (`docs/architecture/06-observability.md#2-step`):
  `/step` (toggle), `/next`, `/decide <value>`, `/continue`, `/break state:<s> | decision:<Type> |
  conf<<x> | clear`. Debug settings apply to the session's live runs and to every run it starts;
  escalation runs never pause. See `docs/architecture/07-harness-frontend.md#interaction-model`.

  **Idle sessions close.** A session with no run in progress and no activity for
  `:idle_timeout` (default 2 hours, `config :xeito, :session_idle_timeout`) stops and frees its
  memory and budget entries. Nothing is lost: its turns are in the workspace log, and `attach`
  (or any request of a client that knows the workspace) rebuilds it.

  Clients subscribe with `subscribe/1` and receive `{:xeito, "session:<id>", event}` where
  `event` is `%{type: type, run: run_id, attrs: map}`. Besides the logged event types, the
  session emits `prompt`, `intent`, `run_selected`, `human_needed`, `turn_finished`, `notice`
  and `error`, plus the runs' `delta` stream.
  """

  use GenServer

  alias Xeito.{Budget, Escalation, Events, Log, Policy, Run, RunSupervisor, Skills}
  alias Xeito.Machines.{Chat, Check, Commit, FixFailingTest, RunTests}
  alias Xeito.Session.{Git, Router}

  # The history window trims with slack: past 80 messages it drops back to 60, so its first
  # message changes once every ~20 messages rather than every turn. The log stores a conversation
  # as a chain from its first message (`Xeito.Log.Store`); a window sliding every turn would
  # start a new chain every turn.
  @max_history 80
  @trimmed_history 60
  @agents_max_bytes 16_384

  # --- client API ----------------------------------------------------------------------------

  @doc """
  Starts a session. Options: `:cwd` (workspace, required), `:id`, `:log` (default: the
  workspace's own log, `Xeito.Log.for_workspace/1`),
  `:decider` (escalation options for decisions: `deciders`, `policy`, `tiers`), `:chat`
  (chat-model overrides), `:test_cmd`, `:system` (replaces the default system prompt),
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
  def child_spec(opts),
    do: %{
      id: {__MODULE__, opts[:id]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }

  @doc "Subscribes the caller to the session's events."
  @spec subscribe(String.t()) :: :ok
  def subscribe(id), do: Events.subscribe(topic(id))

  @doc "Submits a prompt or slash command. Returns `:ok` or `{:error, :busy}`."
  @spec prompt(String.t(), String.t()) :: :ok | {:error, term()}
  def prompt(id, text), do: GenServer.call(via(id), {:prompt, text})

  @doc "Approves the command a run is waiting on."
  @spec approve(String.t()) :: :ok | {:error, :nothing_to_approve}
  def approve(id), do: GenServer.call(via(id), {:human, :approved})

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
  The workspace state for status bars, also emitted as a `workspace` event: git (branch, dirty
  entries, ahead/behind; `nil` outside a repository) and the off-box budget (whether off-box
  tiers are allowed, the limit per run, and what the current run has spent).
  """
  @spec workspace(String.t()) :: map()
  def workspace(id), do: GenServer.call(via(id), :workspace)

  @doc "The session topic for `Xeito.Events`."
  @spec topic(String.t()) :: String.t()
  def topic(id), do: "session:" <> id

  defp via(id), do: {:via, Registry, {Xeito.SessionRegistry, id}}

  # --- server --------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    cwd = opts |> Keyword.fetch!(:cwd) |> Path.expand()
    log = Keyword.get_lazy(opts, :log, fn -> Log.for_workspace(cwd) end)
    id = Keyword.fetch!(opts, :id)

    # Trapping exits lets a clean daemon stop run terminate/2, which records the session closed.
    Process.flag(:trap_exit, true)
    Log.put_object(log, id, "session", %{cwd: cwd, status: "open"})
    Events.subscribe(:all)

    state = %{
      id: id,
      cwd: cwd,
      log: log,
      decider: Keyword.get(opts, :decider, []),
      chat: Keyword.get(opts, :chat, []),
      test_cmd: Keyword.get_lazy(opts, :test_cmd, fn -> Router.test_command(cwd) end),
      system: Keyword.get_lazy(opts, :system, fn -> system_prompt(cwd) end),
      history: [],
      decisions: [],
      debug: %{step: false, breakpoints: []},
      live: MapSet.new(),
      paused: nil,
      turn: 0,
      root: nil,
      machine: nil,
      prompt: nil,
      waiting: nil,
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

  defp schedule_idle_check(s),
    do: Process.send_after(self(), :idle_check, max(div(s.idle_timeout, 4), 10))

  defp busy?(s), do: s.root != nil or s.waiting != nil or s.paused != nil

  # A session id that already has turns in the workspace log is resumed: the conversation is
  # rebuilt from its finished runs. An unfinished run (the daemon stopped mid-turn) is reported,
  # not re-executed.
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
      %{s | history: remember(s, result, answer(machine, result)), machine: nil, prompt: nil}
    else
      _ ->
        %{
          s
          | history: s.history ++ [%{role: "assistant", content: "(turn #{n} was interrupted)"}]
        }
    end
  end

  # Commands that answer or inspect work while a run is busy; anything that starts a run does not.
  # Every request counts as activity for the idle timeout.
  @impl true
  def handle_call(request, from, s), do: handle_request(request, from, %{s | active_at: now()})

  defp handle_request({:prompt, text}, _from, s) do
    trimmed = String.trim(text)

    cond do
      String.match?(
        trimmed,
        ~r{^/(approve|deny|why|budget|help|machines|step|next|continue|break|decide)\b}
      ) ->
        "/" <> command = trimmed
        {:reply, :ok, command(command, s)}

      s.root != nil ->
        {:reply, {:error, :busy}, s}

      true ->
        s = %{s | turn: s.turn + 1, prompt: text}
        emit(s, "prompt", nil, %{"text" => text})

        case trimmed do
          "/" <> command -> {:reply, :ok, command(command, s)}
          _ -> {:reply, :ok, decide_intent(text, s)}
        end
    end
  end

  defp handle_request({:human, _answer}, _from, %{waiting: nil} = s),
    do: {:reply, {:error, :nothing_to_approve}, s}

  defp handle_request({:human, answer}, _from, s) do
    case answer_human(s.waiting.run, answer) do
      :ok -> {:reply, :ok, %{s | waiting: nil}}
      :ignored -> {:reply, {:error, :not_accepted}, s}
    end
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
    emit(s, "workspace", nil, attrs)
    {:reply, attrs, s}
  end

  @impl true
  def handle_info({:intent, text, decision}, s) do
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

    # Small talk needs no tools, and without tools the model's answer streams at once.
    input =
      if machine == Chat and decision.value == :other,
        do: Map.put(input, :tools, false),
        else: input

    {:noreply, start_machine(machine, input, reason, s)}
  end

  def handle_info(:idle_check, s) do
    if not busy?(s) and now() - s.active_at >= s.idle_timeout do
      emit(s, "closed", nil, %{"reason" => "idle", "idle_ms" => s.idle_timeout})
      {:stop, :normal, s}
    else
      schedule_idle_check(s)
      {:noreply, s}
    end
  end

  def handle_info({:xeito, run_id, event}, s) when is_binary(run_id) do
    if String.starts_with?(run_id, s.id <> "/") do
      emit(s, event.type, run_id, event.attrs)
      {:noreply, track(run_id, event, %{s | active_at: now()})}
    else
      {:noreply, s}
    end
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # An idle close (:normal) or a clean daemon stop (:shutdown) records the session closed. A
  # crash records nothing; the next time the workspace log opens, it marks the session
  # `interrupted` (`Xeito.Log`).
  @impl true
  def terminate(reason, s)
      when reason in [:normal, :shutdown] or (is_tuple(reason) and elem(reason, 0) == :shutdown) do
    Budget.delete(s.id)
    Log.put_object(s.log, s.id, "session", %{status: "closed"}, "status")
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, s), do: Budget.delete(s.id)

  # --- prompts -------------------------------------------------------------------------------

  defp decide_intent(text, s) do
    me = self()
    id = "#{s.id}/t#{s.turn}/intent"

    opts =
      [log: s.log, parent: s.id, id: id] ++
        Keyword.take(s.decider, [:deciders, :policy, :tiers, :available?])

    Task.Supervisor.start_child(Xeito.EffectTasks, fn ->
      decision = Escalation.decide(Xeito.Decisions.Intent, %{message: text}, opts)
      send(me, {:intent, text, decision})
    end)

    # Busy until the run starts (and while it runs).
    %{s | root: :deciding}
  end

  defp command(command, s),
    do: command(String.split(command, ~r/\s+/, parts: 2) ++ [""], command, s)

  defp command(["machine", rest | _], _raw, s), do: machine_command(rest, s)
  defp command(["skill:" <> name, rest | _], _raw, s), do: skill_command(name, rest, s)

  defp command(["run", cmd | _], _raw, s) when cmd != "",
    do: start_machine(RunTests, %{cwd: s.cwd, test_cmd: cmd}, "/run", s)

  defp command(["approve" | _], _raw, s), do: human_command(:approved, s)
  defp command(["deny" | _], _raw, s), do: human_command(:denied, s)
  defp command(["why" | _], _raw, s), do: why(s)
  defp command(["budget", usd | _], _raw, s), do: budget(usd, s)
  defp command(["help" | _], _raw, s), do: notice(s, help())
  defp command(["machines" | _], _raw, s), do: notice(s, machines_text(s))
  defp command(["step" | _], _raw, s), do: set_debug(%{s.debug | step: not s.debug.step}, s)
  defp command(["continue" | _], _raw, s), do: set_debug(%{s.debug | step: false}, s)
  defp command(["next" | _], _raw, s), do: step(:next, s)
  defp command(["decide", value | _], _raw, s) when value != "", do: step({:decide, value}, s)

  defp command(["break", "clear" | _], _raw, s),
    do: set_debug(%{s.debug | breakpoints: []}, s)

  defp command(["break", spec | _], _raw, s) when spec != "", do: add_breakpoint(spec, s)
  defp command(_parts, raw, s), do: error(s, "unknown command /#{raw}; try /help")

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

  # `/skill:name args`, as in pi: the skill's instructions become the prompt of a chat turn.
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

        start_machine(Chat, input_for(Chat, prompt, s), "/skill:#{name}", s)
    end
  end

  defp human_command(answer, %{waiting: nil} = s),
    do: error(s, "nothing is waiting for #{answer}")

  defp human_command(answer, s) do
    case answer_human(s.waiting.run, answer) do
      :ok -> %{s | waiting: nil}
      :ignored -> error(s, "the waiting run did not accept #{answer}")
    end
  end

  # Review states take :approved / :denied (the chat machine); a machine's own ask_human state
  # may continue with :answered and stop with :abort (fix_failing_test).
  @fallback %{approved: :answered, denied: :abort}

  defp answer_human(run, answer) do
    with :ignored <- Run.send_event(run, answer, %{}, :human),
         :ignored <- Run.send_event(run, @fallback[answer], %{}, :human) do
      :ignored
    else
      {:ok, _leaf} -> :ok
    end
  catch
    :exit, _ -> :ignored
  end

  # Skills are discovered on every turn, so a new or edited SKILL.md applies at once.
  defp input_for(Chat, text, s) do
    skills = Skills.discover(s.cwd)

    %{
      cwd: s.cwd,
      prompt: text,
      messages: s.history,
      # A turn that edits files is checked before it answers (`Xeito.Machines.Chat`): the quick
      # check (does it still build), not the full suite, which is the `check` machine's job.
      verify: Router.quick_check_command(s.cwd),
      system: s.system <> Skills.prompt_section(skills),
      skills: Enum.map(skills, &Map.take(&1, [:name, :dir]))
    }
  end

  defp input_for(Commit, text, s), do: %{cwd: s.cwd, request: text}

  defp input_for(Check, _text, s),
    do: %{cwd: s.cwd, check_cmd: Router.check_command(s.cwd), system: s.system}

  defp input_for(FixFailingTest, _text, s),
    do: %{cwd: s.cwd, test_cmd: s.test_cmd, delegate: true, system: s.system}

  defp input_for(RunTests, _text, s), do: %{cwd: s.cwd, test_cmd: s.test_cmd}

  defp start_machine(machine, input, reason, s) do
    run_id = "#{s.id}/t#{s.turn}"
    runner = {Xeito.Effects.Local, decider: s.decider, chat: s.chat}

    emit(s, "run_selected", run_id, %{"machine" => inspect(machine), "reason" => reason})

    start = [run_id: run_id, log: s.log, runner: runner, debug: s.debug]

    # The request is kept in the run's input, so a resumed session can rebuild its history.
    input = Map.put_new(input, :request, s.prompt)

    case RunSupervisor.start_run(machine, input, start) do
      {:ok, ^run_id} ->
        Log.relate(s.log, run_id, s.id, "part_of")
        %{s | root: run_id, machine: machine}

      {:error, reason} ->
        error(%{s | root: nil}, "could not start #{inspect(machine)}: #{inspect(reason)}")
    end
  end

  # --- run tracking --------------------------------------------------------------------------

  defp track(run_id, %{type: "state_entered", attrs: %{"state" => :ask_human}}, s) do
    waiting = %{run: run_id, call: pending_call(run_id)}
    emit(s, "human_needed", run_id, %{"call" => waiting.call})
    %{s | waiting: waiting}
  end

  defp track(run_id, %{type: "state_exited", attrs: %{"state" => :ask_human}}, s) do
    if s.waiting && s.waiting.run == run_id, do: %{s | waiting: nil}, else: s
  end

  defp track(run_id, %{type: "run_finished"} = event, %{root: run_id} = s) do
    {:ok, result} = Run.result(s.log, run_id)
    answer = answer(s.machine, result)
    emit(s, "turn_finished", run_id, Map.merge(event.attrs, %{"answer" => answer}))
    # A turn may have edited files or committed: refresh the status bars.
    emit(s, "workspace", nil, workspace_attrs(%{s | root: nil}))

    %{s | root: nil, machine: nil, waiting: nil, history: remember(s, result, answer)}
  end

  defp track(run_id, %{type: "paused"}, s), do: %{s | paused: run_id}

  defp track(run_id, %{type: "run_started"}, s) do
    if internal?(run_id), do: s, else: %{s | live: MapSet.put(s.live, run_id)}
  end

  defp track(run_id, %{type: "run_finished"}, s),
    do: %{s | live: MapSet.delete(s.live, run_id), paused: unpause(s.paused, run_id)}

  defp track(run_id, %{type: type}, s) when type != "delta",
    do: %{s | paused: unpause(s.paused, run_id)}

  defp track(_run_id, _event, s), do: s

  defp unpause(run_id, run_id), do: nil
  defp unpause(paused, _run_id), do: paused

  defp workspace_attrs(s) do
    policy = Policy.effective(Keyword.take(s.decider, [:policy]))
    spent = if is_binary(s.root), do: Budget.get(s.root, :usd), else: 0

    %{
      "git" => Git.status(s.cwd),
      "budget" => %{
        "off_box" => policy.remote == :allowed and policy.locality == :public,
        "max_usd_per_run" => policy.max_usd_per_run,
        "spent_usd" => spent
      }
    }
  end

  defp internal?(run_id),
    do: String.ends_with?(run_id, "/esc") or String.ends_with?(run_id, "/intent")

  # --- step mode -----------------------------------------------------------------------------

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

  def parse_breakpoint("decision:" <> name) do
    module = Module.concat(Xeito.Decisions, Macro.camelize(name))
    if Code.ensure_loaded?(module), do: {:ok, {:decision, module}}, else: :error
  end

  def parse_breakpoint("conf<" <> x) do
    case Float.parse(x) do
      {f, ""} -> {:ok, {:confidence_below, f}}
      _ -> :error
    end
  end

  def parse_breakpoint(_spec), do: :error

  defp pending_call(run_id) do
    case Run.whereis(run_id) && Run.snapshot(run_id) do
      %{ctx: %{current: %{name: name, arguments: args}}} -> %{"tool" => name, "arguments" => args}
      %{ctx: %{review: summary}} -> %{"tool" => "review", "summary" => summary}
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp answer(Chat, %{ctx: ctx}), do: Map.get(ctx, :answer) || Map.get(ctx, :error) |> to_text()

  defp answer(FixFailingTest, %{state: state, ctx: ctx}) do
    fix = get_in(ctx, [:fix, :answer])
    "fix_failing_test ended in #{state}" <> if(fix, do: ": " <> fix, else: "")
  end

  defp answer(machine, %{state: state} = result) do
    ctx = Map.get(result, :ctx, %{})

    Map.get(ctx, :answer) ||
      to_text(Map.get(ctx, :error)) |> default("#{inspect(machine)} ended in #{state}")
  end

  defp default("", fallback), do: fallback
  defp default(text, _fallback), do: text

  defp to_text(nil), do: ""
  defp to_text(text) when is_binary(text), do: text
  defp to_text(other), do: inspect(other)

  # Chat turns keep their full message list; other machines leave a short exchange.
  defp remember(%{machine: Chat}, %{ctx: %{turn: [_system | messages]}}, _answer),
    do: window(messages)

  defp remember(s, _result, answer) do
    (s.history ++
       [%{role: "user", content: s.prompt || ""}, %{role: "assistant", content: answer}])
    |> window()
  end

  defp window(messages) when length(messages) > @max_history,
    do: Enum.take(messages, -@trimmed_history)

  defp window(messages), do: messages

  # --- commands ------------------------------------------------------------------------------

  # The session's own decisions (Intent) plus those its runs logged, newest first.
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
        policy = Keyword.merge(Keyword.get(s.decider, :policy, []), max_usd_per_run: value)
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
    /machines                 list the machines: what they do, how they are routed, usage
    /machine <name> [prompt]  start a machine directly (#{Enum.join(Map.keys(Router.machines()), ", ")})
    /skill:<name> [request]   run a skill (pi / Agent Skills format)
    /run <command>            run a command once
    /approve · /deny          answer a command waiting for review
    /why                      the last decisions, with tier and confidence
    /budget <usd>             off-box spend limit per run
    /quit                     close the client (the session keeps running; attach with --session)
    /statusbar …              TUI only: on|off|reset|segments|show|hide <segment>
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

  defp emit(s, type, run, attrs),
    do: Events.notify(topic(s.id), %{type: type, run: run, attrs: attrs})

  # --- context -------------------------------------------------------------------------------

  @doc false
  def system_prompt(cwd) do
    case File.read(Path.join(cwd, "AGENTS.md")) do
      {:ok, text} ->
        text = binary_part(text, 0, min(byte_size(text), @agents_max_bytes))
        Chat.default_system() <> "\nProject context (AGENTS.md):\n\n" <> text

      {:error, _} ->
        Chat.default_system()
    end
  end

  defp new_id,
    do: "ses-" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
end
