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
end
