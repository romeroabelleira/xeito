import Config

config :xeito,
  log_path: ".xeito/log.sqlite",
  start_log: config_env() != :test,
  # Tests read every append back and compare it with what was written (`Xeito.Log.Store`).
  check_log_roundtrip: config_env() == :test,
  # Where user skills are read from (`Xeito.Skills`, nil: the user's home). Tests read none, so
  # the skills installed on the machine running the suite cannot change what a test sees.
  skills_home: if(config_env() == :test, do: "/nonexistent/xeito-test-home")
