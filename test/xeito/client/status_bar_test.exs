defmodule Xeito.Client.StatusBarTest do
  use ExUnit.Case, async: true

  alias Xeito.Client.StatusBar

  # Only the named segments, on one wide line.
  defp only(names, monitor, workspace \\ nil),
    do: StatusBar.line(StatusBar.new(), monitor, workspace, StatusBar.segments() -- names, 500)

  defp models(models), do: only(~w(models), %{"models" => models})

  describe "the models segment" do
    test "the local tier: loaded (with its unload countdown), idle, down, or not configured" do
      loaded = %{"configured" => true, "up" => true, "loaded" => [%{"name" => "big", "unload_in_s" => 125}]}
      assert models(%{"local" => loaded}) == "local big unload 2:05"
      assert models(%{"local" => %{"configured" => true, "up" => true, "loaded" => [%{"name" => "big"}]}}) == "local big"
      assert models(%{"local" => %{"configured" => true, "up" => true, "loaded" => []}}) == "local idle (not loaded)"
      assert models(%{"local" => %{"configured" => true, "up" => false}}) == "local ✗ down"
      assert models(%{"local" => %{"configured" => false}}) == ""
    end

    test "the local decision model: up or down" do
      assert models(%{"local_decision" => %{"configured" => true, "up" => true}}) == "decision ✓"
      assert models(%{"local_decision" => %{"configured" => true, "up" => false}}) == "decision ✗"
      assert models(%{"local_decision" => %{"configured" => false}}) == ""
    end

    test "nothing before the monitor's first snapshot" do
      assert only(~w(models), nil) == ""
    end
  end

  test "before the monitor's first snapshot, the GPU segment says it is waiting" do
    assert only(~w(gpu), nil) == "status: waiting for the daemon's monitor…"
  end

  test "a missing workspace is flagged in the git segment" do
    assert only(~w(git), nil, %{"missing" => true}) == "⚠ workspace missing"
  end

  test "a remote chat shows its model and what the key has left, beside the budget" do
    budget = %{"off_box" => true, "max_usd_per_run" => 0.5, "spent_usd" => 0.1}
    chat = %{"tier" => "remote_frontier", "model" => "anthropic/claude-x", "off_box" => true, "left_usd" => 29.984}

    assert only(~w(budget), nil, %{"budget" => budget, "chat" => chat}) ==
             "budget $0.40/0.50 │ chat claude-x · key $29.98"

    assert only(~w(budget), nil, %{"budget" => budget, "chat" => %{chat | "left_usd" => nil}}) ==
             "budget $0.40/0.50 │ chat claude-x"

    assert only(~w(budget), nil, %{"budget" => budget, "chat" => %{"off_box" => false, "model" => "q"}}) ==
             "budget $0.40/0.50"
  end

  defp with_events(events), do: Enum.reduce(events, StatusBar.new(), &StatusBar.count(&2, &1))

  defp chat_reply(result), do: %{"event" => "effect_completed", "attrs" => %{"kind" => "chat", "result" => result}}

  defp tokens_line(usage, monitor, workspace),
    do: StatusBar.line(usage, monitor, workspace, StatusBar.segments() -- ~w(tokens), 500)

  describe "the tokens segment" do
    test "the context is measured against the chat tier's window, else the local model's" do
      usage = with_events([chat_reply(%{"tokens_in" => 12_000, "tokens_out" => 300})])
      loaded = %{"models" => %{"local" => %{"loaded" => [%{"context" => 81_920}]}}}
      remote = %{"chat" => %{"context" => 131_072}}

      assert tokens_line(usage, loaded, remote) =~ "ctx 12.0k/131.1k"
      assert tokens_line(usage, loaded, %{"chat" => %{}}) =~ "ctx 12.0k/81.9k"
      assert tokens_line(usage, nil, remote) =~ "ctx 12.0k/131.1k"
    end

    test "remote replies' cache reads, as a share of their input" do
      usage =
        with_events([
          chat_reply(%{"tokens_in" => 10_000, "tokens_out" => 100, "cached_tokens" => 0}),
          chat_reply(%{"tokens_in" => 10_000, "tokens_out" => 100, "cached_tokens" => 9_000}),
          chat_reply(%{"tokens_in" => 5_000, "tokens_out" => 100})
        ])

      assert tokens_line(usage, nil, nil) =~ "cache 45%"
      refute tokens_line(with_events([chat_reply(%{"tokens_in" => 5_000})]), nil, nil) =~ "cache"
    end
  end

  describe "the reply segment" do
    test "a call waiting to be tried again says so until the next reply" do
      retrying = %{"event" => "retrying", "attrs" => %{"attempt" => 2, "of" => 3, "wait_ms" => 3_000, "status" => 429}}
      reply = fn usage -> StatusBar.line(usage, nil, nil, StatusBar.segments() -- ~w(reply), 500) end

      assert reply.(with_events([retrying])) == "retry 2/3 in 3.0 s (429)"
      assert reply.(with_events([retrying, chat_reply(%{"latency_ms" => 900})])) == "reply 900 ms"
    end
  end

  test "a remote chat shows its reasoning effort, when it has one" do
    budget = %{"off_box" => true, "max_usd_per_run" => 0.5, "spent_usd" => 0.0}
    chat = %{"off_box" => true, "model" => "anthropic/claude-x", "reasoning" => "high", "left_usd" => 29.0}
    assert only(~w(budget), nil, %{"budget" => budget, "chat" => chat}) =~ "chat claude-x · high · key $29.00"
  end
end
