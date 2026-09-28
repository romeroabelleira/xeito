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
      model: System.get_env("XEITO_LARGE_MODEL", "qwen3.6:27b"),
      # How long Ollama keeps the model in VRAM after the last request (frees the GPU sooner).
      keep_alive: System.get_env("XEITO_KEEP_ALIVE", "10m")
    ],
    # OpenRouter tier (hosted open-weight models with logprobs). Off-box: gated by Xeito.Policy
    # like the remote tier. XEITO_OPENROUTER_PROVIDERS optionally pins providers (comma list).
    openrouter:
      (if System.get_env("XEITO_OPENROUTER_KEY_FILE") do
         [
           url: System.get_env("XEITO_OPENROUTER_URL", "https://openrouter.ai/api"),
           api_key: key.("XEITO_OPENROUTER_KEY_FILE"),
           model: System.get_env("XEITO_OPENROUTER_MODEL", "qwen/qwen3.6-35b-a3b"),
           providers:
             case System.get_env("XEITO_OPENROUTER_PROVIDERS") do
               nil -> nil
               list -> String.split(list, ",", trim: true)
             end,
           zdr: System.get_env("XEITO_OPENROUTER_ZDR", "true") == "true"
         ]
       else
         []
       end),
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
