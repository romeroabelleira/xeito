import Config

alias Xeito.Tiers.Settings

# Decider tiers, read from the environment (`XEITO_<TIER>_URL`, `_MODEL`, `_KEY_FILE`, …; see
# `Xeito.Tiers.Settings`), so no deployment details live in the repository. A tier that is not
# configured is not used.
if config_env() != :test do
  config :xeito, :tiers, Settings.from_env(System.get_env())

  # The chat tier and the off-box spend limit per run (`XEITO_CHAT_TIER`, `XEITO_MAX_USD_PER_RUN`).
  for {key, value} <- Settings.app_env(System.get_env()), do: config(:xeito, key, value)
end
