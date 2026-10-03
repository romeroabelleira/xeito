import Config

# Decider tiers, read from the environment (`XEITO_<TIER>_URL`, `_MODEL`, `_KEY_FILE`, …; see
# `Xeito.Tiers.Settings`), so no deployment details live in the repository. A tier that is not
# configured is not used.
if config_env() != :test do
  config :xeito, :tiers, Xeito.Tiers.Settings.from_env(System.get_env())
end
