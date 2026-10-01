defmodule Mix.Tasks.Xeito.Mutate do
  @shortdoc "Mutation testing: would the tests notice a wrong line?"
  @moduledoc """
  Mutation testing for source files (`Xeito.Mutate`): each mutant changes one place, is loaded
  over the real module, and the tests run against it. A surviving mutant is behaviour no test
  pins down: add a test (or, for a mutant that cannot change behaviour, say why in review).

      mix xeito.mutate [PATH...] [--test FILE]... [--lines 10-40] [--timeout MS]

  Without paths, it mutates the sources in `test/mutate.exs`, the ones held to zero survivors
  (`mix ci` runs this), against the tests listed there; an entry may limit a source to one
  section (`section: "guards"`, the lines under a `# --- guards ---` comment). A given path uses `--test`, else its
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
    plan = Mutate.plan(paths, Keyword.get_values(opts, :test), config())
    if plan == [], do: Mix.raise("nothing to mutate: give a path, or list sources in #{@config}")

    Mix.Task.run("app.start")
    start_ex_unit(opts)

    survived = Enum.flat_map(plan, &check_source(&1, opts))

    if survived != [], do: Mix.raise("#{length(survived)} mutants survived")
  end

  defp check_source({path, section, tests}, opts) do
    modules = tests |> with_found_tests(path) |> load_tests()
    run_tests = fn -> ExUnit.run(modules) end
    if run_tests.().failures > 0, do: Mix.raise("the tests of #{path} fail on the real code; fix them first")
    mutate(path, section, opts, run_tests)
  end

  defp mutate(path, section, opts, run_tests) do
    source = File.read!(path)
    lines = if section, do: [Mutate.section_lines(source, section)], else: lines(opts)
    results = source |> Mutate.mutants(path, lines: lines) |> Mutate.check(run_tests)
    survived = Enum.filter(results, &(&1.status == :survived))
    source_lines = String.split(source, "\n")
    Enum.each(survived, &Mix.shell().info(Mutate.format(&1, source_lines)))

    s = Mutate.summary(results)

    Mix.shell().info(
      "#{path}#{if section, do: " (#{section})"}: #{length(results)} mutants, #{s.killed} killed, #{s.survived} survived, " <>
        "#{s.invalid} invalid · score #{round(s.score * 100)}%"
    )

    survived
  end

  defp config, do: if(File.exists?(@config), do: @config |> Code.eval_file() |> elem(0), else: %{})

  defp with_found_tests([], path) do
    files = for f <- Path.wildcard("test/**/*_test.exs"), do: {f, File.read!(f)}
    path |> File.read!() |> Mutate.modules() |> Mutate.tests_for(files)
  end

  defp with_found_tests(tests, _path), do: tests

  # ExUnit runs the loaded test modules again for each mutant, quietly, without exiting the VM.
  defp start_ex_unit(opts) do
    Application.put_env(:ex_unit, :autorun, false)
    Code.require_file("test/test_helper.exs")
    ExUnit.configure(formatters: [], timeout: Keyword.get(opts, :timeout, 5_000))
  end

  # Each test file is loaded once, even when several sources share it.
  defp load_tests([]), do: Mix.raise("no tests use these modules; pass --test FILE")

  defp load_tests(files) do
    Mix.shell().info("tests: #{Enum.join(files, ", ")}")

    Enum.flat_map(files, fn file ->
      key = {__MODULE__, Path.expand(file)}

      with nil <- Process.get(key) do
        {:ok, modules, _} = Kernel.ParallelCompiler.require([file], return_diagnostics: true)
        Process.put(key, modules)
      end

      Process.get(key)
    end)
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
