import Config

# Decider tiers. Endpoints and key files come from the environment, so no deployment
# details live in the repository. A tier without a URL is treated as unavailable.
key = fn var ->
  case System.get_env(var) do
    nil -> nil
    path -> path |> Path.expand() |> File.read!() |> String.trim()
  end
end

if config_env() != :test do
  config :xeito, :tiers,
    system_one: [
      url: System.get_env("XEITO_LAYA_URL"),
      api_key: key.("XEITO_LAYA_KEY_FILE"),
      model: System.get_env("XEITO_LAYA_MODEL", "multilingual")
    ],
    small: [
      url: System.get_env("XEITO_LLAMA_URL"),
      api_key: key.("XEITO_LLAMA_KEY_FILE"),
      model: System.get_env("XEITO_SMALL_MODEL", "small")
    ],
    large: [
      url: System.get_env("XEITO_OLLAMA_URL"),
      model: System.get_env("XEITO_LARGE_MODEL", "qwen3.6:27b")
    ],
    # Remote tier (Anthropic Messages API). Unavailable unless an API key file is configured,
    # and even then only used where Xeito.Policy allows it (remote: :allowed, locality: :public).
    remote:
      (if System.get_env("XEITO_ANTHROPIC_KEY_FILE") do
         [
           url: System.get_env("XEITO_ANTHROPIC_URL", "https://api.anthropic.com"),
           api_key: key.("XEITO_ANTHROPIC_KEY_FILE"),
           model: System.get_env("XEITO_REMOTE_MODEL", "claude-opus-5")
         ]
       else
         []
       end)
end
