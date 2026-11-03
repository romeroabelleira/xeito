defmodule Mix.Tasks.Xeito.Plan.Check do
  @shortdoc "Reports where the implementation plan disagrees with the repository"
  @moduledoc """
  Checks `docs/implementation-plan.md` against the repository and reports the disagreements
  (`Xeito.Source.PlanCheck`): modules and mix tasks the plan names that do not exist, anchors and
  relative links that reach nothing, `(checked …)` notes older than 14 days and open items whose
  nearest date is older than 60 days, and milestone rows that disagree with their phase's section.
  Findings are printed by check with their plan line, then counted. With any finding the task
  exits 1, so a scheduled CI step can run it; it changes nothing.

      mix xeito.plan.check
      mix xeito.plan.check --plan docs/implementation-plan.md --root . --today 2026-11-03
  """

  use Mix.Task

  alias Xeito.Source.PlanCheck

  @impl true
  def run(args) do
    if Mix.Tasks.Xeito.help?(args), do: Mix.Tasks.Xeito.help(__MODULE__), else: check(args)
  end

  defp check(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [plan: :string, root: :string, today: :string])
    today = if opts[:today], do: Date.from_iso8601!(opts[:today]), else: Date.utc_today()
    findings = PlanCheck.run(plan: opts[:plan] || "docs/implementation-plan.md", root: opts[:root] || ".", today: today)
    Mix.shell().info(PlanCheck.format(findings))
    if findings == [], do: :ok, else: exit({:shutdown, 1})
  end
end
