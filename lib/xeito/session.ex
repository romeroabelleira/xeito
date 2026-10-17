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
  - A prompt typed while a turn runs is queued. A one-shot turn (`one_shot/3`) names its machine
    or skill and skips steps 1 and 2; it is refused while a turn runs.
  - Step-mode settings (`/step`, `/break`, ...) apply to live and future runs; escalation runs never pause.
  - With no run and no activity for `:idle_timeout` (`config :xeito, :session_idle_timeout`,
    default 2 h) the session stops; its turns stay in the log and an id with logged turns is resumed.

  This module holds the client API, the process and a turn's lifecycle; slash commands
  (`Xeito.Session.Commands`), reviews, the input queue, step mode, history and a turn's input
  are in the modules under `Xeito.Session`, which take and return the state map.

  Events: `{:xeito, "session:<id>", %{type: type, run: run_id, attrs: map}}`, with the logged
  types plus `prompt`, `intent`, `run_selected`, `human_needed`, `turn_finished`, `notice`,
  `error` and the runs' `delta` stream.
  """

  use GenServer

  alias Xeito.Budget
  alias Xeito.Decisions.Intent
  alias Xeito.Escalation
  alias Xeito.Events
  alias Xeito.Log
  alias Xeito.Machines.Chat
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.Session.Allowed
  alias Xeito.Session.Commands
  alias Xeito.Session.History
  alias Xeito.Session.Info
  alias Xeito.Session.Input
  alias Xeito.Session.Notify
  alias Xeito.Session.OneShot
  alias Xeito.Session.Queue
  alias Xeito.Session.Review
  alias Xeito.Session.Router
  alias Xeito.Session.StepMode

  @typedoc "The session's state: the map `init/1` builds, which the `Xeito.Session.*` modules read and update."
  @type state :: map()

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

  @doc "The slash commands the session takes, without the slash."
  @spec commands() :: [String.t()]
  def commands, do: Commands.names()

  @doc "Subscribes the caller to the session's events."
  @spec subscribe(String.t()) :: :ok
  def subscribe(id), do: Events.subscribe(topic(id))

  @doc """
  Submits a prompt or slash command; while a turn runs, a prompt is queued (see `/send`). With a
  `request_id`, a repeat of an admitted one (a client retrying, also after a daemon restart) gets
  the same `:ok` and does nothing.
  """
  @spec prompt(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def prompt(id, text, request_id \\ nil), do: GenServer.call(via(id), {:prompt, text, request_id})

  @doc """
  Starts a turn of `text` with the machine or skill `opts` name and the tools they allow, without
  routing (`Xeito.Session.OneShot`). `{:error, :busy}` while a turn runs, `{:error, message}` for
  what cannot start.
  """
  @spec one_shot(String.t(), String.t(), keyword()) :: :ok | {:error, :busy | String.t()}
  def one_shot(id, text, opts), do: GenServer.call(via(id), {:when_idle, {:one_shot, text, opts}})

  @doc "Stops an idle session, as its idle timeout would; `{:error, :busy}` while a turn runs."
  @spec close(String.t()) :: :ok | {:error, :busy}
  def close(id), do: GenServer.call(via(id), {:when_idle, :close})

  @doc """
  Approves the command a run is waiting on; with scope `"session"` or `"always"`, also remembers it.
  """
  @spec approve(String.t(), String.t() | nil) ::
          :ok
          | {:error, :nothing_to_approve | :not_accepted | :not_a_command | :unknown_scope | {:not_saved, File.posix()}}
  def approve(id, scope \\ nil)
  def approve(id, nil), do: GenServer.call(via(id), {:human, :approved})

  def approve(id, scope) when scope in ["session", "always"],
    do: GenServer.call(via(id), {:human, {:allow, Review.scope(scope)}})

  def approve(_id, _scope), do: {:error, :unknown_scope}

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
      system: Keyword.get_lazy(opts, :system, fn -> Input.system_prompt(cwd) end),
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
      # Request ids of admitted prompts (`prompt/3`), from the log after a restart.
      requests: %{},
      idle_timeout:
        Keyword.get_lazy(opts, :idle_timeout, fn ->
          Application.get_env(:xeito, :session_idle_timeout, 7_200_000)
        end),
      active_at: now()
    }

    schedule_idle_check(state)
    {:ok, History.restore(state)}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp schedule_idle_check(s), do: Process.send_after(self(), :idle_check, max(div(s.idle_timeout, 4), 10))

  defp busy?(s), do: s.root != nil or s.waiting != nil or s.paused != nil

  # Every request counts as activity for the idle timeout.
  @impl true
  def handle_call({:when_idle, request}, _from, s) do
    s = %{s | active_at: now()}
    if busy?(s), do: {:reply, {:error, :busy}, s}, else: when_idle(request, s)
  end

  def handle_call(request, from, s), do: handle_request(request, from, %{s | active_at: now()})

  defp handle_request({:prompt, text, request_id}, _from, s) do
    {reply, s} = admit(text, request_id, s)
    {:reply, reply, s}
  end

  defp handle_request({:human, answer}, _from, s) do
    {reply, s} = Review.answer(answer, s)
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
    attrs = Info.workspace(s)
    Notify.emit(s, "workspace", nil, attrs)
    {:reply, attrs, s}
  end

  defp when_idle(:close, s), do: {:stop, :normal, :ok, s}

  defp when_idle({:one_shot, text, opts}, s) do
    case OneShot.input(text, opts, s) do
      {:ok, machine, input, reason} ->
        log_prompt(String.trim(text), text, nil, s)
        s = %{s | turn: s.turn + 1, prompt: text}
        Notify.emit(s, "prompt", nil, %{"text" => text})
        {:reply, :ok, start_machine(machine, input, reason, s)}

      {:error, message} ->
        {:reply, {:error, message}, s}
    end
  end

  # A prompt whose request id was admitted before is answered and ignored.
  defp admit(_text, request_id, s) when is_map_key(s.requests, request_id), do: {:ok, s}

  defp admit(text, request_id, s) do
    s = if request_id, do: %{s | requests: Map.put(s.requests, request_id, true)}, else: s
    prompt(String.trim(text), text, request_id, warn_if_stale(s))
  end

  # While a review waits, plain text is its answer: what to do instead of the call.
  defp prompt(trimmed, text, request_id, s) do
    log_prompt(trimmed, text, request_id, s)

    cond do
      Regex.match?(
        ~r{^/(approve|deny|halt|send|drop|steer|why|budget|model|help|machines|step|next|continue|break|decide)\b},
        trimmed
      ) ->
        "/" <> command = trimmed
        {:ok, Commands.run(command, s)}

      Review.answers?(trimmed, s) ->
        {:ok, Review.instruct(trimmed, s)}

      s.root != nil ->
        {:ok, Queue.enqueue(text, s)}

      true ->
        {:ok, start_turn(text, trimmed, s)}
    end
  end

  # Typed lines are logged for input history; lines clients send for keys are not.
  @key_lines ~w(/send /drop /halt /next /approve /deny)

  defp log_prompt(trimmed, _text, _request_id, _s) when trimmed in ["" | @key_lines], do: :ok
  defp log_prompt("/approve " <> _scope, _text, _request_id, _s), do: :ok

  defp log_prompt(_trimmed, text, request_id, s),
    do: Notify.log_event(s, "prompt_entered", %{"text" => text, "request_id" => request_id})

  @doc false
  @spec start_turn(String.t(), String.t(), state()) :: state()
  def start_turn(text, trimmed, s) do
    s = %{s | turn: s.turn + 1, prompt: text}
    Notify.emit(s, "prompt", nil, %{"text" => text})

    case trimmed do
      "/" <> command -> Commands.run(command, s)
      _ -> route_prompt(text, trimmed, s)
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

    Notify.emit(s, "intent", nil, %{
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
    input = Input.for_machine(machine, text, s)

    # Only the rule's `other`: a model's `other` can be a reply to an unfinished turn.
    input = if small_talk?(machine, decision, s), do: Map.put(input, :tools, false), else: input
    start_machine(machine, input, reason, s)
  end

  defp small_talk?(machine, decision, s),
    do: machine == Chat and decision.value == :other and decision.actor == :rule and not s.unfinished

  defp idle_check(s) do
    if not busy?(s) and now() - s.active_at >= s.idle_timeout do
      Notify.emit(s, "closed", nil, %{"reason" => "idle", "idle_ms" => s.idle_timeout})
      {:stop, :normal, s}
    else
      schedule_idle_check(s)
      {:noreply, s}
    end
  end

  defp on_run_event(run_id, event, s) do
    if String.starts_with?(run_id, s.id <> "/") do
      Notify.emit(s, event.type, run_id, event.attrs)
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

  # Once per session.
  defp warn_if_stale(%{stale_warned: true} = s), do: s

  defp warn_if_stale(s) do
    if Xeito.Preload.stale?(),
      do:
        Notify.notice(
          %{s | stale_warned: true},
          "· the daemon's code changed on disk since it started (a rebuild or a dependency update), " <>
            "and it keeps running the code it loaded then: restart it to use the new code " <>
            "(systemctl --user restart xeitod, or stop and start mix xeito.daemon)"
        ),
      else: s
  end

  @doc false
  @spec start_machine(module(), map(), String.t(), state()) :: state()
  def start_machine(machine, input, reason, s) do
    run_id = "#{s.id}/t#{s.turn}"
    runner = {Xeito.Effects.Local, decider: s.decider, chat: s.chat}

    Notify.emit(s, "run_selected", run_id, %{"machine" => inspect(machine), "reason" => reason})

    start = [run_id: run_id, log: s.log, runner: runner, debug: s.debug]

    # Kept in the input so a resumed session can rebuild its history.
    input = Map.put_new(input, :request, s.prompt)

    case RunSupervisor.start_run(machine, input, start) do
      {:ok, ^run_id} ->
        Log.relate(s.log, run_id, s.id, "part_of")
        %{s | root: run_id, machine: machine}

      {:error, reason} ->
        Notify.error(%{s | root: nil}, "could not start #{inspect(machine)}: #{inspect(reason)}")
    end
  end

  defp track(run_id, %{type: "state_entered", attrs: %{"state" => :ask_human}}, s), do: Review.entered(run_id, s)
  defp track(run_id, %{type: "state_exited", attrs: %{"state" => :ask_human}}, s), do: Review.ended(run_id, s)

  defp track(run_id, %{type: "run_finished"} = event, %{root: run_id} = s) do
    {:ok, result} = Run.result(s.log, run_id)
    answer = History.answer(s.machine, result)
    # Before `turn_finished`, so that it is the turn's last event and no git runs after it.
    Notify.emit(s, "workspace", nil, Info.workspace(%{s | root: nil}))
    Notify.emit(s, "turn_finished", run_id, Map.put(event.attrs, "answer", answer))

    s = %{
      s
      | root: nil,
        machine: nil,
        waiting: nil,
        history: History.remember(s, result, answer),
        unfinished: History.stopped?(result)
    }

    s |> Queue.requeue_steers(result) |> History.warn_truncated(result) |> after_turn(result, answer)
  end

  defp track(run_id, event, s), do: StepMode.track(run_id, event, s)

  # A normal ending sends the first queued line; otherwise the queue is held.
  defp after_turn(%{queue: []} = s, _result, _answer), do: s
  defp after_turn(%{held: true} = s, _result, _answer), do: s

  defp after_turn(s, result, answer),
    do: if(Queue.release?(result, answer), do: send_queued(s), else: Queue.hold(s, Queue.hold_reason(result)))

  @doc false
  @spec send_queued(state()) :: state()
  def send_queued(s) do
    text = hd(s.queue)
    s = Queue.dequeue(s, "sent")
    {_reply, s} = prompt(String.trim(text), text, nil, s)
    s
  end

  defp new_id, do: "ses-" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
end
