defmodule Xeito.Session.Router do
  @moduledoc """
  Selects the machine for a request: rules over the `Intent` decision and the message, never a
  prompt. Unmatched requests go to the free chat machine, whose logged runs later show which
  new machines are worth writing (`docs/architecture/05-event-log-and-process-mining.md`).

  | intent         | message mentions                    | machine                                      |
  |----------------|-------------------------------------|----------------------------------------------|
  | `edit`         | a failing / red / broken test       | `Xeito.Machines.FixFailingTest` (delegating) |
  | `run` / `edit` | commit                              | `Xeito.Machines.Commit`                      |
  | `run` / `edit` | lint, format, warnings, CI, checks  | `Xeito.Machines.Check`                       |
  | `run`          | tests / specs                       | `Xeito.Machines.RunTests`                    |
  | any            | —                                   | `Xeito.Machines.Chat`                        |

  `/machine <name>` bypasses the intent decision and starts a registered machine directly.
  """

  alias Xeito.Machines.{Chat, Check, Commit, FixFailingTest, RunTests}

  @machines %{
    "chat" => Chat,
    "run_tests" => RunTests,
    "fix_failing_test" => FixFailingTest,
    "commit" => Commit,
    "check" => Check
  }

  @doc "Registered machines by name."
  @spec machines() :: %{String.t() => module()}
  def machines, do: @machines

  @doc "The machine for an intent value and message: `{module, reason}`."
  @spec route(atom(), String.t()) :: {module(), String.t()}
  def route(intent, message) do
    Enum.find_value(rules(), {Chat, "no dedicated machine for intent #{intent}"}, fn
      {intents, match?, machine, reason} ->
        if intent in intents and match?.(message), do: {machine, "intent #{intent}, #{reason}"}
    end)
  end

  # First match wins: {intents, message test, machine, reason}.
  defp rules do
    [
      {[:edit], &failing_test?/1, FixFailingTest, "failing test"},
      {[:run, :edit], &Regex.match?(~r/\bcommit\b/i, &1), Commit, "commit"},
      {[:run, :edit], &checks?/1, Check, "checks"},
      {[:run], &tests?/1, RunTests, "mentions tests"}
    ]
  end

  defp checks?(message),
    do:
      Regex.match?(
        ~r/\b(lint\w*|format\w*|credo|dialyzer|warnings?|ci|checks?|pre-?commit)\b/i,
        message
      )

  defp tests?(message), do: Regex.match?(~r/\b(tests?|specs?|test suite)\b/i, message)

  defp failing_test?(message) do
    Regex.match?(
      ~r/\b(fail\w*|red|broken|breaks?)\b.*\btests?\b|\btests?\b.*\b(fail\w*|red|broken|breaks?)\b/i,
      message
    )
  end

  @doc """
  The check command for a workspace: a `ci` alias in `mix.exs` (`mix ci`), a `check` target in
  the Makefile (`make check`), else formatting, warnings and tests for Mix projects, `npm run
  lint && npm test` when `package.json` has a lint script, and the test command otherwise.
  """
  @spec check_command(Path.t()) :: String.t()
  def check_command(cwd) do
    mix = read(cwd, "mix.exs")
    make = read(cwd, "Makefile")
    npm = read(cwd, "package.json")

    cond do
      mix =~ ~r/\bci:\s*\[/ -> "mix ci"
      make =~ ~r/^check:/m -> "make check"
      mix != "" -> "mix format --check-formatted && mix compile --warnings-as-errors && mix test"
      npm =~ ~r/"lint"\s*:/ -> "npm run lint && npm test"
      true -> test_command(cwd)
    end
  end

  defp read(cwd, file) do
    case File.read(Path.join(cwd, file)) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
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
