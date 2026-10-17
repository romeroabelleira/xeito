defmodule Mix.Tasks.Xeito.Models.Check do
  @shortdoc "Compares the remote tiers' models on OpenRouter with models.dev"
  @moduledoc """
  Compares each configured remote tier's model, as OpenRouter serves it to the tier's key, with
  models.dev's public catalogue, and reports the differences: context window, longest answer,
  prices, and whether the model takes a temperature and tools. It also warns about tier settings
  the model does not take (`Xeito.Tiers.ModelsCheck`).

      mix xeito.models.check

  The tiers come from the environment, as for the daemon (`XEITO_<TIER>_MODEL`, `_KEY_FILE`, …).
  It only reads: both catalogues are free to query.
  """

  use Mix.Task

  alias Xeito.Tiers.ModelsCheck

  @impl true
  def run(args) do
    if Mix.Tasks.Xeito.help?(args), do: Mix.Tasks.Xeito.help(__MODULE__), else: check()
  end

  defp check do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)
    tiers = Application.get_env(:xeito, :tiers, [])
    Mix.shell().info(ModelsCheck.format(ModelsCheck.run(tiers)))
  end
end
