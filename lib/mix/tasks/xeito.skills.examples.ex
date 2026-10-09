defmodule Mix.Tasks.Xeito.Skills.Examples do
  @shortdoc "Writes the skills' example requests with the local model, or shows a skill's"
  @moduledoc """
  The example requests the index searches (`Xeito.Skills.Examples`, P4f step 4).

      mix xeito.skills.examples [--cwd DIR]          # write the missing or stale ones
      mix xeito.skills.examples [--cwd DIR] NAME     # show a skill's

  Writing covers the skills visible from `--cwd` (default: here), the workspace's and the
  user's, one model call each on the local tier (`XEITO_LOCAL_*`). The daemon writes them in
  the background too; this runs it now and reports each skill.
  """

  use Mix.Task

  alias Xeito.Skills
  alias Xeito.Skills.Examples
  alias Xeito.Tiers

  @switches [cwd: :string]

  @impl true
  def run(args) do
    if Mix.Tasks.Xeito.help?(args), do: Mix.Tasks.Xeito.help(__MODULE__), else: run_task(args)
  end

  defp run_task(args) do
    {opts, names, _invalid} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.start")
    skills = Skills.discover(Path.expand(opts[:cwd] || "."))

    case names do
      [] -> write(skills)
      [name | _] -> show(name, skills)
    end
  end

  defp write(skills) do
    cfg = Tiers.config(:local) || Mix.raise("no local tier: set XEITO_LOCAL_URL and XEITO_LOCAL_MODEL")

    case Examples.refresh(skills, cfg) do
      [] -> Mix.shell().info("the examples of #{count(length(skills), "skill")} are up to date")
      results -> Enum.each(results, &Mix.shell().info(line(&1)))
    end
  end

  defp line({name, {:ok, n}}), do: "✓ #{name}: #{count(n, "example")}"
  defp line({name, {:error, reason}}), do: "✗ #{name}: #{inspect(reason)}"

  defp show(name, skills) do
    case skills |> Enum.filter(&(&1.name == name)) |> Examples.attach() do
      [%{examples: [_ | _] = examples}] ->
        Mix.shell().info("#{name} (#{length(examples)}):\n" <> Enum.map_join(examples, "\n", &("  " <> &1)))

      _ ->
        Mix.shell().info("no examples for #{name}: is it a skill, and have its examples been written?")
    end
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
