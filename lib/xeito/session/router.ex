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

  # The registry: name, module, what it does, and how requests reach it (besides /machine).
  @registry [
    {"fix_failing_test", FixFailingTest,
     "reproduce a failing test, triage it, delegate the fix to chat, verify",
     "intent edit + a failing, red or broken test"},
    {"check", Check, "run the project checks; delegate failures to chat until they pass",
     "intent run/edit + lint, format, warnings, CI or checks"},
    {"commit", Commit, "draft a commit message, ask for approval, commit",
     "intent run/edit + commit"},
    {"run_tests", RunTests, "run the test command once", "intent run + tests"},
    {"chat", Chat, "free chat: read/write/edit/bash as effects, bash behind Risk",
     "anything else"}
  ]

  @doc "Registered machines by name."
  @spec machines() :: %{String.t() => module()}
  def machines, do: Map.new(@registry, fn {name, module, _, _} -> {name, module} end)

  @doc """
  The registered machines with their version, summary, routing and states, plus their usage in
  the workspace log (runs by final status and the last run), when that log exists. Delegated
  runs count for the machine that ran (a chat run inside `check` counts as `chat`).
  """
  @spec describe(Path.t(), Xeito.Log.server() | nil) :: [map()]
  def describe(cwd, log \\ nil) do
    usage = usage(log || existing_log(cwd))

    for {name, module, summary, routed} <- @registry do
      machine = Xeito.Machine.fetch!(module)

      %{
        name: name,
        version: machine.version,
        summary: summary,
        routed_from: routed,
        states: machine.states |> Map.values() |> Enum.count(&(not &1.final)),
        usage: Map.get(usage, name, %{runs: 0, done: 0, failed: 0, last: nil})
      }
    end
  end

  defp existing_log(cwd) do
    if File.exists?(Path.join([cwd, ".xeito", "log.sqlite"])),
      do: Xeito.Log.for_workspace(cwd),
      else: nil
  end

  defp usage(nil), do: %{}

  defp usage(log) do
    sql = """
    SELECT r.machine, COUNT(*),
      SUM(CASE WHEN st.status = 'done' THEN 1 ELSE 0 END),
      SUM(CASE WHEN st.status = 'failed' THEN 1 ELSE 0 END),
      MAX(r.ocel_time)
    FROM object_run r
    LEFT JOIN (
      SELECT s.ocel_id, s.status FROM object_run s
      WHERE s.status IS NOT NULL AND s.ocel_time = (
        SELECT MAX(s2.ocel_time) FROM object_run s2
        WHERE s2.ocel_id = s.ocel_id AND s2.status IS NOT NULL)
    ) st ON st.ocel_id = r.ocel_id
    WHERE r.machine IS NOT NULL AND r.ocel_id NOT LIKE '%/esc' AND r.ocel_id NOT LIKE '%/intent'
    GROUP BY r.machine
    """

    for [name, runs, done, failed, last] <- Xeito.Log.query(log, sql), into: %{} do
      {name, %{runs: runs, done: done || 0, failed: failed || 0, last: last}}
    end
  end

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
