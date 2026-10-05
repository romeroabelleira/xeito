import Config

config :xeito,
  log_path: ".xeito/log.sqlite",
  start_log: config_env() != :test,
  # Tests read every append back and compare it with what was written (`Xeito.Log.Store`).
  check_log_roundtrip: config_env() == :test,
  # Where user skills are read from (`Xeito.Skills`, nil: the user's home). Tests read none, so
  # the skills installed on the machine running the suite cannot change what a test sees.
  skills_home: if(config_env() == :test, do: "/nonexistent/xeito-test-home"),
  # The home whose `.xeito/` holds the user's own state: skill examples and their log
  # (`Xeito.Skills.Examples`; nil: the user's home). Tests use a scratch one.
  state_home: if(config_env() == :test, do: Path.join(System.tmp_dir!(), "xeito-test-state")),
  # Executables taken as installed or not (`Xeito.Executables`; unset: the PATH decides). Tests
  # take the task runners as absent unless they set them.
  executables: if(config_env() == :test, do: %{"just" => false, "mise" => false}, else: %{})
