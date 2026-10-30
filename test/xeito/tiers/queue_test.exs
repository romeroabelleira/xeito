defmodule Xeito.Tiers.QueueTest do
  @moduledoc "Background calls (P4f step 4) take a tier's slot only when no other call waits for it."
  use Xeito.Case, async: true

  alias Xeito.Tiers.Queue

  # A tier of its own per test: unknown tiers have one slot.
  defp tier, do: :"queue_test_#{System.unique_integer([:positive])}"

  # A call that reports when it runs and holds the slot until told to finish.
  defp hold(tier, priority) do
    test = self()

    Task.async(fn ->
      Queue.run(
        tier,
        fn ->
          send(test, {:running, self()})
          receive do: (:finish -> :ok)
        end,
        :infinity,
        priority
      )
    end)
  end

  test "a background call waits until no other call waits" do
    tier = tier()
    first = hold(tier, :normal)
    assert_receive {:running, pid} when pid == first.pid

    background = hold(tier, :background)
    eventually(fn -> Queue.status(tier) == {1, 1} end)
    normal = hold(tier, :normal)
    eventually(fn -> Queue.status(tier) == {1, 2} end)

    send(first.pid, :finish)
    assert_receive {:running, pid} when pid == normal.pid
    refute_received {:running, _}

    send(normal.pid, :finish)
    assert_receive {:running, pid} when pid == background.pid
    send(background.pid, :finish)

    Task.await_many([first, normal, background])
    assert Queue.status(tier) == {0, 0}
  end

  test "a background call runs at once when the slot is free" do
    tier = tier()
    background = hold(tier, :background)
    assert_receive {:running, pid} when pid == background.pid
    send(background.pid, :finish)
    Task.await(background)
  end

  test "background calls are served in the order they came" do
    tier = tier()
    first = hold(tier, :normal)
    assert_receive {:running, _}
    a = hold(tier, :background)
    eventually(fn -> Queue.status(tier) == {1, 1} end)
    b = hold(tier, :background)
    eventually(fn -> Queue.status(tier) == {1, 2} end)

    send(first.pid, :finish)
    assert_receive {:running, pid} when pid == a.pid
    send(a.pid, :finish)
    assert_receive {:running, pid} when pid == b.pid
    send(b.pid, :finish)
    Task.await_many([first, a, b])
  end

  test "capacity/1: rules are not queued; local tiers have one slot, remote ones four, unknown ones one" do
    assert Queue.capacity(:rules) == :infinity
    assert Queue.capacity(:local) == 1
    assert Queue.capacity(:remote) == 4
    assert Queue.capacity(tier()) == 1
  end

  test "a tier admits at most its capacity of calls at once; the next waits for a slot to free" do
    # A remote tier: four slots by default.
    tier = :remote_frontier
    four = for _ <- 1..4, do: hold(tier, :normal)
    for _ <- four, do: assert_receive({:running, _})

    fifth = hold(tier, :normal)
    eventually(fn -> Queue.status(tier) == {4, 1} end)
    refute_received {:running, _}

    [first | rest] = four
    send(first.pid, :finish)
    assert_receive {:running, pid} when pid == fifth.pid

    for task <- rest ++ [fifth], do: send(task.pid, :finish)
    Task.await_many(four ++ [fifth])
    assert Queue.status(tier) == {0, 0}
  end
end
