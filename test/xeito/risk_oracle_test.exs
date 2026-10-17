defmodule Xeito.RiskOracleTest do
  @moduledoc """
  P4k step 6: every Risk example with a fixture is run, undone and run twice (`Xeito.RiskOracle`).
  Its labels must match what happens, and the rules must claim nothing undo or a second run does
  not keep. Real commands run, so the tag `:oracle` keeps it out of `mix test`; `mix ci` runs it.
  """
  use ExUnit.Case, async: true

  alias Xeito.Decision.Eval
  alias Xeito.Decisions.Risk
  alias Xeito.RiskOracle

  @moduletag :oracle
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  test "labels hold, and the rules claim nothing undo or a second run would not keep", %{tmp_dir: dir} do
    runnable =
      Risk
      |> Eval.examples(workspaces: Path.join(dir, "fresh"))
      |> Enum.filter(&(&1.fixture != nil and &1.label != :forbidden and installed?(&1.input.command)))

    assert length(runnable) >= 60

    results =
      runnable
      |> Enum.with_index()
      |> Task.async_stream(
        fn {ex, i} -> {ex, findings(ex, RiskOracle.observe(ex.input.command, ex.fixture, Path.join(dir, "#{i}")))} end,
        max_concurrency: 8,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert for({ex, [_ | _] = found} <- results, ex.gap == nil, do: {ex.fixture, ex.input.command, found}) == []
    # A gap stays marked only while the oracle still finds it.
    assert for({ex, []} <- results, ex.gap != nil, do: {ex.gap, ex.input.command}) == []
  end

  defp installed?(command), do: command |> String.split() |> hd() |> System.find_executable() != nil

  defp findings(ex, seen) do
    command = ex.input.command
    safe = Risk.classify(ex.input) == :safe

    labels(ex, seen) ++
      check(
        safe and seen.changed != [] and (seen.undoable != true or seen.outside),
        "safe by rule, but undo does not restore it"
      ) ++
      check(
        Risk.repeatable?(command) and (seen.changed != [] or not seen.repeatable),
        "repeatable by rule, but it is not"
      ) ++
      check(safe and not within_written?(command, seen.changed), "safe by rule, but it changes paths it does not name")
  end

  defp labels(ex, seen) do
    check(seen.undoable != ex.undoable, "labelled undoable #{inspect(ex.undoable)}, observed #{inspect(seen.undoable)}") ++
      check(
        seen.repeatable != ex.repeatable,
        "labelled repeatable #{inspect(ex.repeatable)}, observed #{seen.repeatable}"
      )
  end

  defp check(true, finding), do: [finding]
  defp check(false, _finding), do: []

  # Every changed workspace path lies under a path the rules say the command writes.
  defp within_written?(command, changed) do
    {:ok, written} = Risk.written_paths(command)

    changed
    |> Enum.filter(&String.starts_with?(&1, "ws/"))
    |> Enum.all?(fn "ws/" <> path ->
      Enum.any?(written, &(path == Path.relative(&1) or String.starts_with?(path, String.trim_trailing(&1, "/") <> "/")))
    end)
  end
end
