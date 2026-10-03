defmodule Xeito.ChatWindowTest do
  @moduledoc "The context window of a chat request: estimating it and fitting a conversation into it."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xeito.Chat.Window

  defp system(text \\ "You are a coding assistant."), do: %{role: "system", content: text}
  defp user(text), do: %{role: "user", content: text}
  defp assistant(text \\ ""), do: %{role: "assistant", content: text}

  defp tool(n, chars) do
    %{
      role: "tool",
      tool_name: "bash",
      content: String.duplicate("x", chars),
      ref: "ses/t/e#{n}",
      about: "output of `cmd #{n}`"
    }
  end

  # An earlier turn: the user's line, the model's call, its result, the model's answer.
  defp turn(n, chars), do: [user("request #{n}"), assistant(), tool(n, chars), assistant("done #{n}")]

  defp fit(messages, opts), do: Window.fit(messages, Keyword.put_new(opts, :chars_per_token, 1.0))

  describe "estimate" do
    test "characters per token plus a few tokens per message for the template" do
      assert Window.estimate([user(String.duplicate("a", 300))], 3.0) == 100 + 4
      assert Window.estimate([user("")], 3.0) == 4
      assert Window.estimate([], 3.0) == 0
    end

    test "tool calls count with their arguments" do
      call = %{
        role: "assistant",
        content: "",
        tool_calls: [%{function: %{name: "bash", arguments: %{"command" => "ls"}}}]
      }

      assert Window.estimate([call], 1.0) > Window.estimate([assistant()], 1.0)
    end

    test "a message without text content counts only its overhead" do
      assert Window.estimate([%{role: "assistant", content: nil}], 1.0) == 4
    end
  end

  describe "fit" do
    test "a conversation within the budget is sent unchanged" do
      messages = [system(), user("hi")]
      assert {:ok, ^messages, %{dropped: 0, stubbed: 0, shortened: 0}} = fit(messages, budget: 1_000, keep_from: 1)
    end

    test "a conversation exactly at the budget fits; one token over does not fit unchanged" do
      # system("") is 4 tokens, user("abcdef") 10: 14 in all at one character per token.
      messages = [system(""), user("abcdef")]
      assert {:ok, ^messages, %{dropped: 0, stubbed: 0, shortened: 0}} = fit(messages, budget: 14, keep_from: 1)
      assert {:error, {:over_budget, 14, 13}} = fit(messages, budget: 13, keep_from: 1)
    end

    test "a system prompt that leaves no room at all is an error" do
      assert {:error, {:system_too_large, 4, 4}} = fit([system(""), user("hi")], budget: 4, keep_from: 1)
    end

    test "first, old tool outputs become stubs; the last ones stay whole" do
      outputs = Enum.map(1..6, &tool(&1, 600))
      messages = [system(), user("task")] ++ Enum.flat_map(outputs, &[assistant(), &1])

      assert {:ok, fitted, %{stubbed: 2, dropped: 0}} = fit(messages, budget: 3_100, keep_from: 1)
      assert [%{content: "[elided" <> _}, %{content: "[elided" <> _} | whole] = for(%{role: "tool"} = m <- fitted, do: m)
      assert length(whole) == 4 and Enum.all?(whole, &(String.length(&1.content) == 600))
    end

    test "then the oldest earlier turns are dropped whole, with a note; the current turn stays" do
      earlier = turn(1, 500) ++ turn(2, 500) ++ turn(3, 500)
      current = [user("now"), assistant()]
      messages = [system()] ++ earlier ++ current

      assert {:ok, fitted, %{dropped: 8}} = fit(messages, budget: 700, keep_from: 1 + length(earlier))
      assert [%{role: "system"}, %{role: "user", content: "[8 earlier messages" <> _} | rest] = fitted
      assert rest == turn(3, 500) ++ current
    end

    test "a tool result is never separated from the call before it" do
      earlier = [assistant(), tool(1, 400)] ++ turn(2, 400)
      messages = [system()] ++ earlier ++ [user("now")]

      {:ok, fitted, _} = fit(messages, budget: 500, keep_from: 1 + length(earlier))
      refute Enum.any?(Enum.chunk_every(fitted, 2, 1), &match?([%{role: "user"}, %{role: "tool"}], &1))
      refute match?([_, %{role: "tool"} | _], fitted)
    end

    test "last, the largest message of the current turn is shortened in the middle" do
      big = user("HEAD" <> String.duplicate("m", 5_000) <> "TAIL")
      messages = [system(), big]

      assert {:ok, [_system, %{content: content}], %{shortened: 1}} = fit(messages, budget: 3_000, keep_from: 1)
      assert String.starts_with?(content, "HEAD") and String.ends_with?(content, "TAIL")
      # 5_008 characters: the first and last 1_252 stay, the 2_504 between them go.
      assert content =~ "[… 2504 characters cut to fit the context window …]"
    end

    test "a message of 2000 characters or fewer is never shortened" do
      # Shortened, it would fit (about 1_060 tokens); at exactly 2_000 characters it stays whole.
      messages = [system(""), user(String.duplicate("m", 2_000))]
      assert {:error, {:over_budget, _, 1_100}} = fit(messages, budget: 1_100, keep_from: 1)

      assert {:ok, _, %{shortened: 1}} =
               fit([system(""), user(String.duplicate("m", 2_001))], budget: 1_100, keep_from: 1)
    end

    test "a system prompt larger than the budget is an error, never cut" do
      assert {:error, {:system_too_large, _tokens, 100}} =
               fit([system(String.duplicate("s", 500)), user("hi")], budget: 100, keep_from: 1)
    end

    test "a conversation that cannot be made to fit is an error" do
      messages = [system()] ++ Enum.map(1..40, &user("short line #{&1}"))
      assert {:error, {:over_budget, _tokens, 200}} = fit(messages, budget: 200, keep_from: 1)
    end

    property "the system prompt and the current prompt always reach the model unchanged" do
      check all(
              n_earlier <- integer(0..6),
              sizes <- list_of(integer(10..800), length: n_earlier),
              prompt <- string(:alphanumeric, min_length: 1, max_length: 200),
              budget <- integer(400..4_000)
            ) do
        earlier = sizes |> Enum.with_index() |> Enum.flat_map(fn {size, i} -> turn(i, size) end)
        messages = [system()] ++ earlier ++ [user(prompt)]

        case fit(messages, budget: budget, keep_from: 1 + length(earlier)) do
          {:ok, fitted, _} ->
            assert hd(fitted) == system()
            assert List.last(fitted) == user(prompt)
            assert Window.estimate(fitted, 1.0) <= budget

          {:error, _reason} ->
            :ok
        end
      end
    end
  end

  describe "stubs" do
    defp result(content, extra \\ %{}),
      do: Map.merge(%{role: "tool", tool_name: "bash", content: content, ref: "r1"}, extra)

    test "a tool result is elidable when it is longer than 400 characters and can be read back" do
      assert Window.elidable?(result(String.duplicate("x", 401)))
      refute Window.elidable?(result(String.duplicate("x", 400)))
      refute Window.elidable?(Map.delete(result(String.duplicate("x", 401)), :ref))
      refute Window.elidable?(result(nil))
    end

    test "skill instructions and messages other than tool results are never elidable" do
      refute Window.elidable?(result(String.duplicate("x", 401), %{tool_name: "skill"}))
      refute Window.elidable?(%{role: "user", content: String.duplicate("x", 401), ref: "r1"})
    end

    test "a stub names what the result was: its description, else the tool, else a tool call" do
      long = String.duplicate("x\n", 300)

      assert Window.stub(result(long, %{about: "output of `ls`"})).content =~
               "[elided to save context: output of `ls` (301 lines)."

      assert Window.stub(result(long)).content =~ "[elided to save context: bash ("
      assert Window.stub(Map.delete(result(long), :tool_name)).content =~ "[elided to save context: tool call ("
      assert Window.stub(result(long)).content =~ ~s(read with result: "r1")
    end
  end

  describe "calibrate" do
    test "the measured characters per token, within sane bounds" do
      assert Window.calibrate(3_500, 1_000) == 3.5
      assert Window.calibrate(1_000, 1_000) == 2.0
      assert Window.calibrate(9_000, 1_000) == 4.5
    end

    test "without a measurement, the conservative default" do
      assert Window.calibrate(3_500, 0) == 3.0
    end
  end

  describe "truncated?" do
    test "a prompt cut by the server comes back as half its context plus two" do
      assert Window.truncated?(32_770, 65_536)
      assert Window.truncated?(16_387, 32_768)
      refute Window.truncated?(30_000, 65_536)
      # n_ctx/2 itself is a prompt that just fits, not a cut one; nor is anything below it.
      refute Window.truncated?(32_768, 65_536)
      refute Window.truncated?(32_767, 65_536)
      assert Window.truncated?(32_769, 65_536) and Window.truncated?(32_771, 65_536)
      refute Window.truncated?(32_772, 65_536)
      refute Window.truncated?(32_770, nil)
    end
  end
end
