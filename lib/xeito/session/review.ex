defmodule Xeito.Session.Review do
  @moduledoc """
  A run waiting in `ask_human`: what it waits on, and the human's answer (`/approve`, `/deny`, or text).

  The session state's `waiting` is `%{run: run_id, call: call}` while a run waits, nil otherwise;
  `allowed` holds the commands approved for the session (`Xeito.Session.Allowed`). `entered/3`
  either waits, emitting `human_needed`, or approves a command allowed before at once, with the
  scope in the log. Answers reach the run as `:human` events; a machine's own review that takes
  `:answered` / `:abort` (fix_failing_test) gets those instead of `:approved` / `:denied`.
  """

  alias Xeito.Run
  alias Xeito.Session
  alias Xeito.Session.Allowed
  alias Xeito.Session.Notify
  alias Xeito.Tools

  @type answer :: :approved | :denied | {:allow, Allowed.scope()}

  @allow_errors %{
    nothing_to_approve: "nothing is waiting for approval",
    not_a_command: "only a shell command can be allowed; /approve answers this review",
    not_accepted: "the waiting run did not accept approved"
  }

  # Fallback for a machine's own ask_human state, which takes :answered / :abort (fix_failing_test).
  @fallback %{approved: :answered, denied: :abort}

  @doc "The scope of `/approve session` or `/approve always`."
  @spec scope(String.t()) :: Allowed.scope()
  def scope("session"), do: :session
  def scope("always"), do: :always

  @doc "Runs `/approve [session|always]` or `/deny`, emitting an error when nothing takes the answer."
  @spec command(String.t(), String.t(), Session.state()) :: Session.state()
  def command("approve", "", s), do: human_command(:approved, s)
  def command("approve", scope, s) when scope in ["session", "always"], do: allow_command(scope(scope), s)
  def command("approve", arg, s), do: Notify.error(s, "/approve takes session or always, not #{inspect(arg)}")
  def command("deny", _arg, s), do: human_command(:denied, s)

  @doc "Answers the waiting run for the client API; `{:allow, scope}` also remembers the command."
  @spec answer(answer(), Session.state()) :: {:ok | {:error, term()}, Session.state()}
  def answer(_answer, %{waiting: nil} = s), do: {{:error, :nothing_to_approve}, s}
  def answer({:allow, scope}, s), do: allow(scope, s)

  def answer(answer, s) do
    case answer_human(s.waiting.run, answer) do
      :ok -> {:ok, %{s | waiting: nil}}
      :ignored -> {{:error, :not_accepted}, s}
    end
  end

  @doc "Whether a typed line answers the waiting review: plain, non-empty text while a run waits."
  @spec answers?(String.t(), Session.state()) :: boolean()
  def answers?(trimmed, s), do: s.waiting != nil and trimmed != "" and not String.starts_with?(trimmed, "/")

  @doc "Sends text to the waiting run as what to do instead of its call."
  @spec instruct(String.t(), Session.state()) :: Session.state()
  def instruct(text, s) do
    case Run.send_event(s.waiting.run, :instructed, %{text: text}, :human) do
      {:ok, _leaf} -> %{s | waiting: nil}
      :ignored -> Notify.error(s, "this review takes y or n only (/approve, /deny)")
    end
  catch
    :exit, _ -> Notify.error(s, "the waiting run is gone")
  end

  @doc "A run entered `ask_human`: waits for the human, or approves a command allowed before."
  @spec entered(String.t(), Session.state()) :: Session.state()
  def entered(run_id, s) do
    call = pending_call(run_id)

    case Allowed.scope(s.cwd, s.allowed, call) do
      nil -> wait_for_human(run_id, call, s)
      scope -> skip_review(run_id, call, scope, s)
    end
  end

  @doc "A run left `ask_human`: it no longer waits."
  @spec ended(String.t(), Session.state()) :: Session.state()
  def ended(run_id, s), do: if(s.waiting && s.waiting.run == run_id, do: %{s | waiting: nil}, else: s)

  defp human_command(answer, %{waiting: nil} = s), do: Notify.error(s, "nothing is waiting for #{answer}")

  defp human_command(answer, s) do
    case answer_human(s.waiting.run, answer) do
      :ok -> %{s | waiting: nil}
      :ignored -> Notify.error(s, "the waiting run did not accept #{answer}")
    end
  end

  defp allow_command(scope, s) do
    case answer({:allow, scope}, s) do
      {:ok, s} -> s
      {{:error, reason}, s} -> Notify.error(s, allow_error(reason))
    end
  end

  defp allow_error({:not_saved, reason}), do: "approved, but .xeito/allowed.json could not be written: #{inspect(reason)}"
  defp allow_error(reason), do: Map.fetch!(@allow_errors, reason)

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
      {:ok, allowed} ->
        {:ok, Notify.notice(%{s | allowed: allowed}, "approved · `#{command}` is now #{allowed_how(scope)}")}

      {:error, reason} ->
        {{:error, {:not_saved, reason}}, s}
    end
  end

  defp allowed_how(:session), do: "allowed for this session"
  defp allowed_how(:always), do: "always allowed in this workspace (.xeito/allowed.json)"

  defp answer_human(run, answer, data \\ %{}) do
    with :ignored <- Run.send_event(run, answer, data, :human),
         :ignored <- Run.send_event(run, @fallback[answer], data, :human) do
      :ignored
    else
      {:ok, _leaf} -> :ok
    end
  catch
    :exit, _ -> :ignored
  end

  defp wait_for_human(run_id, call, s) do
    Notify.emit(s, "human_needed", run_id, %{"call" => call})
    %{s | waiting: %{run: run_id, call: call}}
  end

  # Allowed before: approved as the human would, with the scope in the log.
  defp skip_review(run_id, call, scope, s) do
    {:ok, command} = Allowed.command(call)

    case answer_human(run_id, :approved, %{allowed: scope}) do
      :ok -> Notify.notice(s, "· `#{command}` runs without asking: #{allowed_how(scope)}")
      :ignored -> wait_for_human(run_id, call, s)
    end
  end

  defp pending_call(run_id) do
    case Run.whereis(run_id) && Run.snapshot(run_id) do
      %{ctx: %{current: %{name: name, arguments: args}}} -> runs_for(%{"tool" => name, "arguments" => args})
      %{ctx: %{review: summary}} -> %{"tool" => "review", "summary" => summary}
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  # The timeout the command will actually get, not what the model asked.
  defp runs_for(%{"tool" => "bash", "arguments" => %{"timeout_s" => asked}} = call),
    do: Map.put(call, "runs_for_s", div(Tools.bash_timeout_ms(asked), 1_000))

  defp runs_for(call), do: call
end
