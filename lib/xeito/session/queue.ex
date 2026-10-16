defmodule Xeito.Session.Queue do
  @moduledoc """
  Input while a turn runs: lines queued for later, and steers for a running chat turn.

  The session state's `queue` holds the lines typed while a turn ran, oldest first; `held` is set
  when a turn did not end normally, and then nothing is sent until `/send`. Every change emits an
  event (`queued`, `dequeued`, `queue_held`, `steered`) and queuing or dequeuing is logged in the
  session's stream for input history. A queued line is never taken as a review's answer.
  """

  alias Xeito.Machines.Chat
  alias Xeito.Run
  alias Xeito.Session
  alias Xeito.Session.History
  alias Xeito.Session.Notify

  @doc "Appends a line to the queue."
  @spec enqueue(String.t(), Session.state()) :: Session.state()
  def enqueue(text, s) do
    queue = s.queue ++ [text]
    Notify.emit(s, "queued", nil, %{"text" => text, "queued" => length(queue)})
    Notify.log_event(s, "prompt_queued", %{"text" => text})
    %{s | queue: queue}
  end

  @doc "Steers the running turn: a chat turn takes the line at its next model call; otherwise it is queued."
  @spec steer(String.t(), Session.state()) :: Session.state()
  def steer(text, %{machine: Chat, root: run} = s) when is_binary(run) do
    case Run.send_event(run, :steered, %{text: text}, :human) do
      {:ok, _leaf} ->
        Notify.emit(s, "steered", run, %{"text" => text})
        s

      _not_taken ->
        enqueue(text, s)
    end
  end

  def steer(text, s),
    do: s |> Notify.notice("steering reaches a chat turn only; queued instead") |> then(&enqueue(text, &1))

  @doc "Queues the steers a finished chat turn did not deliver."
  @spec requeue_steers(Session.state(), map()) :: Session.state()
  def requeue_steers(s, result), do: result.ctx |> Chat.undelivered() |> Enum.reduce(s, &enqueue/2)

  @doc "Whether a finished turn sends the first queued line: done, not stopped at its step limit, and not asking a question."
  @spec release?(map(), term()) :: boolean()
  def release?(result, answer),
    do:
      result.status == :done and not History.stopped?(result) and
        not (answer |> to_string() |> String.trim() |> String.ends_with?("?"))

  @doc "Why a finished turn holds the queue: `halted`, `failed`, `stopped` or `question`."
  @spec hold_reason(map()) :: String.t()
  def hold_reason(%{status: status}) when status in [:halted, :failed], do: to_string(status)
  def hold_reason(%{ctx: %{stopped: true}}), do: "stopped"
  def hold_reason(_result), do: "question"

  @doc "Holds a non-empty queue for `reason`."
  @spec hold(Session.state(), String.t()) :: Session.state()
  def hold(%{queue: []} = s, _reason), do: s

  def hold(s, reason) do
    Notify.emit(s, "queue_held", nil, %{"reason" => reason, "queued" => length(s.queue)})
    %{s | held: true}
  end

  @doc "Takes the first queued line off the queue, as `sent` or `dropped` (`outcome`)."
  @spec dequeue(Session.state(), String.t()) :: Session.state()
  def dequeue(%{queue: [text | rest]} = s, outcome) do
    Notify.emit(s, "dequeued", nil, %{"text" => text, "outcome" => outcome})
    Notify.log_event(s, "prompt_dequeued", %{"text" => text, "outcome" => outcome})
    %{s | queue: rest, held: s.held and rest != []}
  end
end
