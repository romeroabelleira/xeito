defmodule Mix.Tasks.Xeito.Mutate do
  @shortdoc "Mutation testing: would the tests notice a wrong line?"
  @moduledoc """
  Mutation testing for source files (`Xeito.Mutate`): each mutant changes one place, is loaded
  over the real module, and the tests run against it. A surviving mutant is behaviour no test
  pins down: add a test (or, for a mutant that cannot change behaviour, say why in review).

      mix xeito.mutate [PATH...] [--test FILE]... [--lines 10-40] [--timeout MS]

  Without paths, it mutates the sources in `test/mutate.exs`, the ones held to zero survivors
  (`mix ci` runs this), against the tests listed there. A given path uses `--test`, else its
  tests from that file, else the files under `test/` that use its modules. The tests must pass on
  the real code first. `--lines` mutates only those lines (repeatable); `--timeout` is the
  per-test timeout in ms (default 5000; a mutant that loops is killed by it).

  Fails when a mutant survives. Runs in the test environment.
  """

  use Mix.Task

  alias Xeito.Mutate

  @switches [test: :keep, lines: :keep, timeout: :integer]
  @config "test/mutate.exs"

  @impl true
  def run(args) do
    {opts, paths, _} = OptionParser.parse(args, strict: @switches)
    {paths, test_files} = Mutate.plan(paths, Keyword.get_values(opts, :test), config())
    if paths == [], do: Mix.raise("nothing to mutate: give a path, or list sources in #{@config}")

    Mix.Task.run("app.start")
    tests = load_tests(with_found_tests(test_files, paths), opts)
    run_tests = fn -> ExUnit.run(tests) end
    if run_tests.().failures > 0, do: Mix.raise("the tests fail on the real code; fix them first")

    survived = Enum.flat_map(paths, &mutate(&1, opts, run_tests))
    if survived != [], do: Mix.raise("#{length(survived)} mutants survived")
  end

  defp mutate(path, opts, run_tests) do
    source = File.read!(path)
    results = source |> Mutate.mutants(path, lines: lines(opts)) |> Mutate.check(run_tests)
    survived = Enum.filter(results, &(&1.status == :survived))
    lines = String.split(source, "\n")
    Enum.each(survived, &Mix.shell().info(Mutate.format(&1, lines)))

    s = Mutate.summary(results)

    Mix.shell().info(
      "#{path}: #{length(results)} mutants, #{s.killed} killed, #{s.survived} survived, " <>
        "#{s.invalid} invalid · score #{round(s.score * 100)}%"
    )

    survived
  end

  defp config, do: if(File.exists?(@config), do: @config |> Code.eval_file() |> elem(0), else: %{})

  defp with_found_tests([], paths) do
    modules = Enum.flat_map(paths, &(&1 |> File.read!() |> Mutate.modules()))
    files = for f <- Path.wildcard("test/**/*_test.exs"), do: {f, File.read!(f)}
    Mutate.tests_for(modules, files)
  end

  defp with_found_tests(tests, _paths), do: tests

  # ExUnit runs the loaded test modules again for each mutant, quietly, without exiting the VM.
  defp load_tests([], _opts), do: Mix.raise("no tests use these modules; pass --test FILE")

  defp load_tests(files, opts) do
    Application.put_env(:ex_unit, :autorun, false)
    Code.require_file("test/test_helper.exs")
    ExUnit.configure(formatters: [], timeout: Keyword.get(opts, :timeout, 5_000))
    Mix.shell().info("tests: #{Enum.join(files, ", ")}")
    {:ok, modules, _} = Kernel.ParallelCompiler.require(files, return_diagnostics: true)
    modules
  end

  defp lines(opts) do
    case Keyword.get_values(opts, :lines) do
      [] -> nil
      ranges -> Enum.map(ranges, &range/1)
    end
  end

  defp range(text) do
    case String.split(text, "-") do
      [a, b] -> String.to_integer(a)..String.to_integer(b)
      [a] -> String.to_integer(a)..String.to_integer(a)
    end
  end
end
