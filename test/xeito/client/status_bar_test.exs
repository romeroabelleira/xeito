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

  test "lines/2: usage, determinism budget and system line from events and a snapshot" do
    events = [
      %{"event" => "intent", "attrs" => %{"actor" => "rule"}},
      %{
        "event" => "decision_made",
        "run" => "s/t1",
        "attrs" => %{
          "actor" => "local",
          "tokens_in" => 300,
          "tokens_out" => 5,
          "joules_est" => 150.0
        }
      },
      %{
        "event" => "decision_made",
        "run" => "s/t1/e2/esc",
        "attrs" => %{"actor" => "local", "tokens_in" => 999}
      },
      %{
        "event" => "effect_completed",
        "run" => "s/t1",
        "attrs" => %{"kind" => "chat", "result" => %{"tokens_in" => 3200, "tokens_out" => 120}}
      },
      %{"event" => "transition", "run" => "s/t1", "attrs" => %{"actor" => "code"}},
      %{"event" => "transition", "run" => "s/t1", "attrs" => %{"actor" => "rule"}},
      %{"event" => "transition", "run" => "s/t1", "attrs" => %{"actor" => "local"}},
      %{"event" => "transition", "run" => "s/t1", "attrs" => %{"actor" => "human"}}
    ]

    usage = Enum.reduce(events, StatusBar.new(), &StatusBar.count(&2, &1))
    assert usage.calls == %{"rule" => 1, "local" => 1, "chat" => 1}
    assert {usage.tokens_in, usage.tokens_out, usage.ctx} == {3500, 125, 3200}

    snapshot = %{
      "system" => %{
        "cpu" => %{"busy_pct" => 23.4, "load1" => 1.2},
        "mem" => %{"used_bytes" => 18_360_000_000, "total_bytes" => 66_571_993_088},
        "gpus" => [
          %{"primary" => false, "vram_used_bytes" => 1, "vram_total_bytes" => 2},
          %{
            "primary" => true,
            "vram_used_bytes" => 19_860_000_000,
            "vram_total_bytes" => 25_753_026_560,
            "busy_pct" => 97,
            "power_w" => 290.5,
            "temps_c" => %{"edge" => 61.0, "junction" => 74.5}
          }
        ]
      },
      "models" => %{
        "local" => %{
          "configured" => true,
          "up" => true,
          "loaded" => [%{"name" => "big:27b", "unload_in_s" => 252, "context" => 81_920}]
        },
        "local_decision" => %{"configured" => true, "up" => false},
        "remote" => %{"configured" => false}
      },
      "queues" => %{
        "local" => %{"in_use" => 1, "waiting" => 2},
        "local_decision" => %{"in_use" => 0, "waiting" => 0}
      }
    }

    [system, use] = StatusBar.lines(usage, snapshot)

    assert system ==
             "GPU 18.5/24.0 GiB 97% 291 W 75°C │ local big:27b unload 4:12 │ decision ✗ │ CPU 23% load 1.2 RAM 17.1/62.0 GiB"

    assert use ==
             "chat 1 · local 1 · rule 1 │ 3.5k→125 tok · ctx 3.2k/81.9k │ det 50% │ $0.0000 · ~150 J │ queue local 1+2"

    assert [_, _] = StatusBar.lines(StatusBar.new(), nil)
  end

  test "lines/4: latency of the last decision and the last model reply" do
    usage =
      Enum.reduce(
        [
          %{"event" => "intent", "attrs" => %{"actor" => "local", "latency_ms" => 833}},
          %{
            "event" => "effect_completed",
            "run" => "s/t1",
            "attrs" => %{"kind" => "chat", "result" => %{"latency_ms" => 2140, "first_token_ms" => 410}}
          },
          %{
            "event" => "decision_made",
            "run" => "s/t1",
            "attrs" => %{"decision_type" => "Xeito.Decisions.Risk", "actor" => "rule", "latency_ms" => 3}
          }
        ],
        StatusBar.new(),
        &StatusBar.count(&2, &1)
      )

    hidden = ~w(gpu models cpu git calls tokens det cost budget queue)

    assert StatusBar.lines(usage, nil, nil, hidden) == [
             "risk rule 3 ms │ reply 2.1 s (first 410 ms)"
           ]

    only_intent =
      StatusBar.count(StatusBar.new(), %{
        "event" => "intent",
        "attrs" => %{"actor" => "local", "latency_ms" => 1250}
      })

    assert StatusBar.lines(only_intent, nil, nil, hidden) == ["intent local 1.3 s"]
  end

  test "lines/4: the git and budget segments of a workspace report; nothing when every segment is hidden" do
    # As a client sees it: JSON keys.
    workspace = %{
      "git" => %{"branch" => "work", "dirty" => 1, "ahead" => 1, "behind" => 0},
      "budget" => %{"off_box" => true, "max_usd_per_run" => 0.25, "spent_usd" => 0.05}
    }

    [line1, line2] = StatusBar.lines(StatusBar.new(), nil, workspace, ~w(tokens det cost))
    assert line1 == "status: waiting for the daemon's monitor… │ git work 1 changed ↑1"
    assert line2 == "no model calls yet │ budget $0.20/0.25"

    assert StatusBar.lines(
             StatusBar.new(),
             nil,
             %{"budget" => %{"off_box" => false}},
             ~w(gpu calls tokens det cost)
           ) ==
             ["off-box off"]

    assert StatusBar.lines(StatusBar.new(), nil, nil, StatusBar.segments()) == []
  end

  test "line/5: one line, filled by priority up to the width" do
    usage = StatusBar.new()
    line = StatusBar.line(usage, nil, nil, [], 40)
    assert String.length(line) <= 40 and line =~ "tok"
    refute line =~ "\n"
    assert String.length(StatusBar.line(usage, nil, nil, [], 200)) > 40
    assert StatusBar.line(usage, nil, nil, StatusBar.segments(), 80) == ""
  end

  test "line/5 keeps the higher-priority segment when two do not fit" do
    usage = StatusBar.new()
    only = StatusBar.segments() -- ~w(calls tokens)
    both = StatusBar.line(usage, nil, nil, only, 200)
    assert both =~ "no model calls yet" and both =~ "tok"

    # Exactly wide enough: both; one less: the higher-priority tokens segment alone.
    assert StatusBar.line(usage, nil, nil, only, String.length(both)) == both
    narrow = StatusBar.line(usage, nil, nil, only, String.length(both) - 1)
    assert narrow =~ "tok" and not (narrow =~ "calls")
  end
end
