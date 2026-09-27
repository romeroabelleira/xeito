import Config

config :xeito,
  log_path: ".xeito/log.sqlite",
  start_log: config_env() != :test
