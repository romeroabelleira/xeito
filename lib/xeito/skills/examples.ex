defmodule Xeito.Skills.Examples do
  @moduledoc """
  Example requests per skill, written by the local model (P4f step 4, "doc2query"): requests a
  user would type that the skill serves, in their own words. The index searches them
  (`Xeito.Skills.Index`), so a request finds a skill by what it means even when it shares no
  word with the skill's description, at no cost per turn.

  Generation costs a model call per skill, so its result is cached: one JSON file per skill
  under `~/.xeito/skills/examples` (`home/0`), keyed by the hash of
  its `SKILL.md`, the model and the model's digest. An edited skill, another model or new
  weights under the same tag make it stale (`stale/4`), and `refresh/3` writes it again. Until
  then the examples of an unchanged `SKILL.md` stay in use (`attach/2`), whatever wrote them.

  Each generation is a logged model call (`skill_examples_generated`, stream
  `skills/examples`), and it waits for the local tier as a background call
  (`Xeito.Tiers.Queue`), behind every interactive one.
  """

  alias Xeito.Backends
  alias Xeito.Log
  alias Xeito.Skills
  alias Xeito.Tiers.Queue

  @count 15
  @body 4_000

  @schema %{
    "type" => "object",
    "properties" => %{
      "requests" => %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 5, "maxItems" => 20}
    },
    "required" => ["requests"]
  }

  @system """
  You write the requests a user types to an AI coding assistant. Given a skill the assistant can \
  use, write #{@count} short, varied requests that this skill serves, as a user would type them: \
  plain words, the way people ask, mostly without the skill's name or its description's words. \
  Mix situations, lengths and phrasings. One request per item, no numbering.
  """

  @doc "The home whose `.xeito/` holds the cache and the log: `config :xeito, :state_home`, else the user's."
  @spec home() :: Path.t()
  def home, do: Application.get_env(:xeito, :state_home) || System.user_home!()

  @doc "The cache directory."
  @spec dir() :: Path.t()
  def dir, do: Path.join([home(), ".xeito", "skills", "examples"])

  @doc "Asks the model in `cfg` for example requests for `skill`."
  @spec generate(Skills.t(), keyword()) ::
          {:ok,
           %{
             examples: [String.t()],
             tokens_in: non_neg_integer(),
             tokens_out: non_neg_integer(),
             latency_ms: non_neg_integer()
           }}
          | {:error, term()}
  def generate(skill, cfg) do
    started = System.monotonic_time(:millisecond)

    body = %{
      model: Keyword.fetch!(cfg, :model),
      stream: false,
      think: false,
      format: @schema,
      options: Backends.context_options(cfg, %{temperature: 0}),
      keep_alive: Keyword.get(cfg, :keep_alive, "10m"),
      messages: [%{role: "system", content: @system}, %{role: "user", content: describe(skill)}]
    }

    opts = [method: :post, url: "/api/chat", json: body] ++ Backends.req_options(Keyword.put_new(cfg, :timeout, 300_000))

    case Req.request(opts) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}} = resp}} -> answer(content, resp, started)
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp describe(skill) do
    body = skill |> Skills.body() |> String.slice(0, @body)
    "Skill: #{skill.name}\nDescription: #{skill.description}\n\nInstructions:\n#{body}"
  end

  defp answer(content, resp, started) do
    case JSON.decode(content) do
      {:ok, %{"requests" => requests}} when is_list(requests) ->
        {:ok,
         %{
           examples: requests |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
           tokens_in: resp["prompt_eval_count"] || 0,
           tokens_out: resp["eval_count"] || 0,
           latency_ms: System.monotonic_time(:millisecond) - started
         }}

      _ ->
        {:error, :invalid_answer}
    end
  end

  @doc "The digest Ollama lists for the model in `cfg` (`nil` if it lists none)."
  @spec digest(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def digest(cfg) do
    model = Keyword.fetch!(cfg, :model)

    case Req.request([method: :get, url: "/api/tags"] ++ Backends.req_options(cfg)) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        {:ok, Enum.find_value(models, &(&1["name"] == model && &1["digest"]))}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Caches `entry` (`:model`, `:digest`, `:examples`) for the current `SKILL.md` of `skill`."
  @spec put(Skills.t(), map(), Path.t()) :: :ok
  def put(skill, entry, dir \\ dir()) do
    File.mkdir_p!(dir)
    json = JSON.encode!(%{hash: hash(skill), model: entry.model, digest: entry.digest, examples: entry.examples})
    File.write!(path(dir, skill), json)
  end

  @doc "The skills, each with the cached examples of its current `SKILL.md` (`[]` if none)."
  @spec attach([Skills.t()], Path.t()) :: [Skills.t()]
  def attach(skills, dir \\ dir()) do
    Enum.map(skills, fn skill ->
      examples =
        case current(skill, dir) do
          %{"examples" => examples} -> examples
          _ -> []
        end

      Map.put(skill, :examples, examples)
    end)
  end

  @doc "The skills whose examples are missing, or were written for another `SKILL.md`, model or digest."
  @spec stale([Skills.t()], String.t(), String.t() | nil, Path.t()) :: [Skills.t()]
  def stale(skills, model, digest, dir \\ dir()),
    do: Enum.reject(skills, &match?(%{"model" => ^model, "digest" => ^digest}, current(&1, dir)))

  @doc """
  Generates and caches the examples of the stale skills, one at a time, each a background call
  on the local tier. Options: `:dir` (the cache), `:log` (where generations are logged).
  Returns `[{name, {:ok, count} | {:error, reason}}]`.
  """
  @spec refresh([Skills.t()], keyword(), keyword()) :: [{String.t(), {:ok, non_neg_integer()} | {:error, term()}}]
  def refresh(skills, cfg, opts \\ []) do
    dir = Keyword.get_lazy(opts, :dir, &dir/0)
    log = Keyword.get_lazy(opts, :log, fn -> Log.for_workspace(home()) end)

    digest =
      case digest(cfg) do
        {:ok, digest} -> digest
        _ -> nil
      end

    for skill <- stale(skills, cfg[:model], digest, dir) do
      {skill.name,
       :local
       |> Queue.run(fn -> generate(skill, cfg) end, :infinity, :background)
       |> keep(skill, cfg[:model], digest, dir, log)}
    end
  end

  defp keep({:ok, result}, skill, model, digest, dir, log) do
    put(skill, %{model: model, digest: digest, examples: result.examples}, dir)

    attrs = %{
      skill: skill.name,
      skill_hash: hash(skill),
      model: model,
      digest: digest,
      count: length(result.examples),
      tokens_in: result.tokens_in,
      tokens_out: result.tokens_out,
      latency_ms: result.latency_ms
    }

    {:ok, _} =
      Log.append(log, "skills/examples", [
        Log.Event.new("skill_examples_generated", {:skill_examples_generated, attrs}, attrs)
      ])

    {:ok, length(result.examples)}
  end

  defp keep(error, _skill, _model, _digest, _dir, _log), do: error

  # The cache entry for the skill's current `SKILL.md`, if any.
  defp current(skill, dir) do
    with {:ok, json} <- File.read(path(dir, skill)),
         {:ok, %{"hash" => hash} = entry} <- JSON.decode(json),
         ^hash <- hash(skill) do
      entry
    else
      _ -> nil
    end
  end

  defp path(dir, skill), do: Path.join(dir, skill.name <> ".json")

  defp hash(skill) do
    case File.read(Path.join(skill.dir, "SKILL.md")) do
      {:ok, text} -> :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
      {:error, _} -> nil
    end
  end
end
