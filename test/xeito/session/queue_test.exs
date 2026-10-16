defmodule Xeito.Session.QueueTest do
  use ExUnit.Case, async: true

  alias Xeito.Session.Queue

  test "release?/2: only a turn that ended done, not stopped, and without a question sends the queue" do
    done = %{status: :done, ctx: %{}}
    assert Queue.release?(done, "The tests pass.")
    refute Queue.release?(done, "Which file did you mean?\n")
    refute Queue.release?(%{status: :done, ctx: %{stopped: true}}, "I ran out of steps.")
    refute Queue.release?(%{status: :halted, ctx: %{}}, "(halted)")
    refute Queue.release?(%{status: :failed, ctx: %{}}, "boom")
  end
end
