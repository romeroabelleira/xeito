defmodule Xeito.Session.Router do
  @moduledoc """
  Selects the machine for a request: rules over the `Intent` decision and the message, never a
  prompt. Unmatched requests go to the free chat machine, whose logged runs later show which
  new machines are worth writing (`docs/architecture/05-event-log-and-process-mining.md`).

  | intent | message mentions            | machine                                   |
  |--------|-----------------------------|-------------------------------------------|
  | `run`  | tests / specs               | `Xeito.Machines.RunTests`                 |
  | `edit` | a failing / red / broken test | `Xeito.Machines.FixFailingTest` (delegating) |
  | any    | —                           | `Xeito.Machines.Chat`                     |

  `/machine <name>` bypasses the intent decision and starts a registered machine directly.
  """

  alias Xeito.Machines.{Chat, FixFailingTest, RunTests}

  @machines %{
    "chat" => Chat,
    "run_tests" => RunTests,
    "fix_failing_test" => FixFailingTest
  }

  @doc "Registered machines by name."
  @spec machines() :: %{String.t() => module()}
  def machines, do: @machines

  @doc "The machine for an intent value and message: `{module, reason}`."
  @spec route(atom(), String.t()) :: {module(), String.t()}
  def route(intent, message) do
    cond do
      intent == :run and tests?(message) -> {RunTests, "intent run, mentions tests"}
      intent == :edit and failing_test?(message) -> {FixFailingTest, "intent edit, failing test"}
      true -> {Chat, "no dedicated machine for intent #{intent}"}
    end
  end

  defp tests?(message), do: Regex.match?(~r/\b(tests?|specs?|test suite)\b/i, message)

  defp failing_test?(message) do
    Regex.match?(
      ~r/\b(fail\w*|red|broken|breaks?)\b.*\btests?\b|\btests?\b.*\b(fail\w*|red|broken|breaks?)\b/i,
      message
    )
  end

  @doc """
  The test command for a workspace, from its build files: `mix test`, `npm test`, `pytest`,
  `cargo test`, `go test ./...`, else `make test`.
  """
  @spec test_command(Path.t()) :: String.t()
  def test_command(cwd) do
    [
      {"mix.exs", "mix test"},
      {"package.json", "npm test"},
      {"pyproject.toml", "pytest"},
      {"setup.py", "pytest"},
      {"Cargo.toml", "cargo test"},
      {"go.mod", "go test ./..."}
    ]
    |> Enum.find_value("make test", fn {file, cmd} ->
      if File.exists?(Path.join(cwd, file)), do: cmd
    end)
  end
end
