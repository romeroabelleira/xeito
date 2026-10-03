defmodule Xeito.SessionQueueTest do
  use Xeito.Case, async: false

  alias Xeito.Session

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-queue-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    log = start_log!()
    {:ok, id} = Session.start(cwd: ws, log: log, id: "ses-q-#{System.unique_integer([:positive])}")
    Session.subscribe(id)
    %{id: id, log: log, ws: ws}
  end

  defp event(type, timeout \\ 5_000) do
    assert_receive {:xeito, _, %{type: ^type, attrs: attrs}}, timeout
    attrs
  end

  # A turn that keeps the session busy until halted, its command already running.
  defp busy(id) do
    :ok = Session.prompt(id, "/run sleep 5")
    assert_receive {:xeito, _, %{type: "effect_requested"}}, 2_000
  end

  test "a line typed while a turn runs is queued, and sent when the turn ends normally", %{id: id, ws: ws} do
    :ok = Session.prompt(id, "/run sleep 0.3")
    assert_receive {:xeito, _, %{type: "effect_requested"}}, 2_000

    assert :ok = Session.prompt(id, "/run touch q.txt")
    assert %{"text" => "/run touch q.txt", "queued" => 1} = event("queued")

    assert %{"status" => :done} = event("turn_finished")
    assert %{"text" => "/run touch q.txt", "outcome" => "sent"} = event("dequeued")
    assert %{"status" => :done} = event("turn_finished")
    assert File.exists?(Path.join(ws, "q.txt"))
  end

  test "a turn that ends halted holds the queue: /send sends the first line, /drop drops it", %{id: id, ws: ws} do
    busy(id)
    :ok = Session.prompt(id, "/run touch a.txt")
    :ok = Session.prompt(id, "/run touch b.txt")
    assert %{"queued" => 1} = event("queued")
    assert %{"queued" => 2} = event("queued")

    :ok = Session.prompt(id, "/halt")
    assert %{"status" => :halted} = event("turn_finished")
    assert %{"reason" => "halted", "queued" => 2} = event("queue_held")
    refute_receive {:xeito, _, %{type: "dequeued"}}, 300

    :ok = Session.prompt(id, "/drop")
    assert %{"text" => "/run touch a.txt", "outcome" => "dropped"} = event("dequeued")

    :ok = Session.prompt(id, "/send")
    assert %{"text" => "/run touch b.txt", "outcome" => "sent"} = event("dequeued")
    assert %{"status" => :done} = event("turn_finished")
    assert File.exists?(Path.join(ws, "b.txt"))
    refute File.exists?(Path.join(ws, "a.txt"))
  end

  test "a held queue stays held across turns until it is sent or dropped", %{id: id} do
    busy(id)
    :ok = Session.prompt(id, "/run true")
    :ok = Session.prompt(id, "/halt")
    assert %{"status" => :halted} = event("turn_finished")
    assert %{"reason" => "halted"} = event("queue_held")

    :ok = Session.prompt(id, "/run true")
    assert %{"status" => :done} = event("turn_finished")
    refute_receive {:xeito, _, %{type: "dequeued"}}, 300
  end

  test "/send and /drop with nothing queued, and /send while a turn runs", %{id: id} do
    :ok = Session.prompt(id, "/send")
    assert %{"text" => "nothing is queued"} = event("error")
    :ok = Session.prompt(id, "/drop")
    assert %{"text" => "nothing is queued"} = event("error")

    busy(id)
    :ok = Session.prompt(id, "/run true")
    :ok = Session.prompt(id, "/send")
    assert %{"text" => "a turn is running; queued lines are sent when it ends"} = event("error")
    :ok = Session.prompt(id, "/halt")
  end

  test "commands for the running turn still act at once", %{id: id} do
    busy(id)
    :ok = Session.prompt(id, "/help")
    assert %{"text" => "/help" <> _} = event("notice")
    refute_receive {:xeito, _, %{type: "queued"}}, 200
    :ok = Session.prompt(id, "/halt")
  end

  test "queued and dequeued lines are logged in the session's stream", %{id: id, log: log} do
    busy(id)
    :ok = Session.prompt(id, "/run true")
    :ok = Session.prompt(id, "/halt")
    event("queue_held")
    :ok = Session.prompt(id, "/drop")
    event("dequeued")

    assert Xeito.Log.query(log, "SELECT text FROM event_prompt_queued") == [["/run true"]]
    assert Xeito.Log.query(log, "SELECT text, outcome FROM event_prompt_dequeued") == [["/run true", "dropped"]]
  end

  test "/steer while another machine runs is queued, with a note; idle, it is a prompt", %{id: id, ws: ws} do
    busy(id)
    :ok = Session.prompt(id, "/steer use pytest")
    assert %{"text" => "steering reaches a chat turn only; queued instead"} = event("notice")
    assert %{"text" => "use pytest"} = event("queued")
    :ok = Session.prompt(id, "/halt")
    assert %{"status" => :halted} = event("turn_finished")
    event("queue_held")
    :ok = Session.prompt(id, "/drop")
    event("dequeued")

    :ok = Session.prompt(id, "/steer /run touch s.txt")
    assert %{"status" => :done} = event("turn_finished")
    assert File.exists?(Path.join(ws, "s.txt"))

    :ok = Session.prompt(id, "/steer")
    assert %{"text" => "/steer <text>: a line for the running chat turn, taken at its next model call"} = event("error")
  end

  test "release?/2: only a turn that ended done, not stopped, and without a question sends the queue" do
    done = %{status: :done, ctx: %{}}
    assert Session.release?(done, "The tests pass.")
    refute Session.release?(done, "Which file did you mean?\n")
    refute Session.release?(%{status: :done, ctx: %{stopped: true}}, "I ran out of steps.")
    refute Session.release?(%{status: :halted, ctx: %{}}, "(halted)")
    refute Session.release?(%{status: :failed, ctx: %{}}, "boom")
  end
end
