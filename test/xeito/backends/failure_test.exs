defmodule Xeito.Backends.FailureTest do
  use ExUnit.Case, async: true

  alias Xeito.Backends.Failure

  describe "classify/4" do
    test "a request longer than the model's window" do
      for text <- [
            "This endpoint's maximum context length is 131072 tokens. However, you requested about 140000 tokens",
            ~s({"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}),
            "Input is too long for requested model",
            "context_length_exceeded"
          ],
          do: assert(Failure.classify(400, text, [], 1) == :overflow, text)
    end

    test "quota and billing refusals, which a retry cannot fix" do
      assert Failure.classify(402, "This request requires more credits", [], 1) == :quota
      assert Failure.classify(429, ~s({"error":{"message":"insufficient_quota"}}), [], 1) == :quota
      assert Failure.classify(403, "Key limit exceeded", [], 1) == :quota
    end

    test "transient failures are retried, waiting as the server asks or backing off" do
      assert Failure.classify(429, "rate limited", [{"retry-after", "2"}], 1) == {:retry, 2_000}
      assert Failure.classify(503, "busy", [{"retry-after-ms", "1500"}], 1) == {:retry, 1_500}
      assert Failure.classify(502, "bad gateway", [], 1) == {:retry, 1_000}
      assert Failure.classify(500, "oops", [], 2) == {:retry, 2_000}
      assert Failure.classify(:transport, "timeout", [], 3) == {:retry, 4_000}

      for status <- [408, 409, 504], do: assert({:retry, _} = Failure.classify(status, "", [], 1))
    end

    test "a server that asks to wait more than a minute fails at once" do
      assert Failure.classify(429, "slow down", [{"retry-after", "61"}], 1) == :other
      assert Failure.classify(429, "slow down", [{"retry-after", "60"}], 1) == {:retry, 60_000}
    end

    test "anything else is neither retried nor explained" do
      assert Failure.classify(400, "bad request", [], 1) == :other
      assert Failure.classify(401, "no auth", [], 1) == :other
    end
  end

  describe "run/2" do
    defp sleeps, do: fn ms -> send(self(), {:slept, ms}) end

    test "a retryable failure is tried again, at most three times in all" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      call = fn ->
        case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
          n when n < 3 -> {:failed, 503, "busy", []}
          _ -> {:ok, :answer}
        end
      end

      assert Failure.run(call, sleep: sleeps()) == {:ok, :answer}
      assert_received {:slept, 1_000}
      assert_received {:slept, 2_000}

      Agent.update(calls, fn _ -> -10 end)
      assert {:error, {:http, 503, "busy"}} = Failure.run(call, sleep: sleeps())
    end

    test "an overflow, a quota refusal and a transport error say what happened" do
      assert {:error, {:context_overflow, text}} = Failure.run(fn -> {:failed, 400, "maximum context length", []} end)
      assert text =~ "longer than the model's context window"

      assert {:error, {:quota, text}} = Failure.run(fn -> {:failed, 402, "requires more credits", []} end)
      assert text =~ "/model local"

      assert {:error, :closed} = Failure.run(fn -> {:error, :closed} end, sleep: sleeps(), attempts: 1)
      assert {:error, :broken} = Failure.run(fn -> {:final, :broken} end, sleep: sleeps())
      refute_received {:slept, _}
    end

    test "each retry is announced before the wait, with its attempt, wait and cause" do
      parent = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      call = fn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:failed, 429, "slow", [{"retry-after", "3"}]}
          1 -> {:error, :timeout}
          _ -> {:ok, :answer}
        end
      end

      on_retry = &send(parent, {:retry, &1})
      assert Failure.run(call, sleep: sleeps(), on_retry: on_retry) == {:ok, :answer}
      assert_received {:retry, %{attempt: 2, of: 3, wait_ms: 3_000, status: 429}}
      assert_received {:retry, %{attempt: 3, of: 3, wait_ms: 2_000, status: "connection"}}
    end

    test "a transport error is retried like a transient failure" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      call = fn ->
        if Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) == 0, do: {:error, :timeout}, else: {:ok, :answer}
      end

      assert Failure.run(call, sleep: sleeps()) == {:ok, :answer}
    end
  end
end
