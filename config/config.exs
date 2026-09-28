import Config

config :xeito,
  log_path: ".xeito/log.sqlite",
  start_log: config_env() != :test,
  # Tests read every append back and compare it with what was written (`Xeito.Log.Store`).
  check_log_roundtrip: config_env() == :test
