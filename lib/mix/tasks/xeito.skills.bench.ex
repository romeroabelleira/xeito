defmodule Mix.Tasks.Xeito.Skills.Bench do
  @shortdoc "Measures how well requests find the skills they need"
  @moduledoc """
  Runs a benchmark set against a skill library and reports how often the chat turn's shortlist
  holds the skill a request needs (`Xeito.Skills.Bench`, P4f step 1).

      mix xeito.skills.bench [SET] [--skills DIR]...

  Without a set, the shipped sample set runs against the sample library. With a set, the library
  is the user's (`~/.agents/skills`) unless `--skills` names one or more directories.
  """

  use Mix.Task

  alias Xeito.Skills
  alias Xeito.Skills.Bench

  @switches [skills: :keep]

  @impl true
  def run(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("compile")
    {set, default_dirs} = set(rest)
    if !File.exists?(set), do: Mix.raise("no benchmark set at #{set}")

    dirs = with [] <- Keyword.get_values(opts, :skills), do: default_dirs
    report = Bench.run(Skills.from_dirs(dirs), Bench.read_set(set))
    Mix.shell().info(String.trim_trailing(Bench.format(report)))
  end

  defp set([]), do: {Bench.sample_set(), [Bench.sample_skills()]}
  defp set([path | _]), do: {path, [Skills.user_dir()]}
end
