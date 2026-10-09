defmodule Xeito.Tools do
  @moduledoc """
  The core tools, as in pi: `read`, `write`, `edit`, `bash`. Each tool call a model makes is
  turned into an `Xeito.Effect`, so it is logged, replayable and executed by the policy-checked
  runner, never by the model client.

  * `read` and `write`/`edit` are confined to the workspace by `Xeito.Effects.Local`.
  * `write`/`edit` refuse directories that edits do not belong in: fetched dependencies and build
    output (`deps/`, `_build/`, `node_modules/`), git's own data (`.git/`) and Xeito's log
    (`.xeito/`). Dependencies are not rebuilt from edited sources and are replaced on the next
    fetch, so such an edit looks done but never takes; the model is told why and what to do.
  * `bash` commands pass the `Xeito.Decisions.Risk` decision first (see `Xeito.Machines.Chat`).
    A command may run for `timeout_s` seconds (default 60, at most `max_bash_timeout_s/0`); one
    stopped at its timeout tells the model how to give it longer.
  * `skill` (offered only when skills are available, `Xeito.Skills`) reads a file of a skill,
    confined to that skill's directory; `SKILL.md` by default.
  * An unknown tool name or malformed arguments become an error result for the model, not a
    crash: the set of tools is closed, like a typed decision's values.
  """

  alias Xeito.Effect

  @names ~w(read write edit bash)

  # How long a model's command may run, in seconds. The chat machine's `executing` state must
  # outlast the longest, and its stop (`Xeito.Machines.Chat`).
  @default_bash_timeout_s 60
  @max_bash_timeout_s 600

  @doc "The longest a model may ask a `bash` command to run, in seconds."
  @spec max_bash_timeout_s() :: pos_integer()
  def max_bash_timeout_s, do: @max_bash_timeout_s

  @doc """
  The timeout, in milliseconds, of a `bash` call whose `timeout_s` argument is `seconds`, capped
  at the maximum. One that is not a positive number gets the default: a model's slip is not
  worth a failed call. Small models often send numbers as strings, so those are read too.
  """
  @spec bash_timeout_ms(term()) :: pos_integer()
  def bash_timeout_ms(seconds) when is_binary(seconds), do: seconds |> Float.parse() |> parsed_seconds()

  def bash_timeout_ms(seconds) when is_number(seconds) and seconds > 0,
    do: round(min(seconds, @max_bash_timeout_s) * 1_000)

  def bash_timeout_ms(_other), do: @default_bash_timeout_s * 1_000

  defp parsed_seconds({seconds, ""}), do: bash_timeout_ms(seconds)
  defp parsed_seconds(_not_a_number), do: bash_timeout_ms(nil)

  @doc "The core tool names."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  The tools offered in a run with context `ctx`: none when `ctx.tools == false`, else the core
  tools, plus `skill` when the run has skills.
  """
  @spec names_for(map()) :: [String.t()]
  def names_for(%{tools: false}), do: []
  def names_for(%{skills: [_ | _]}), do: @names ++ ["skill"]
  def names_for(_ctx), do: @names

  @doc "OpenAI-style function specs for `names`, as accepted by Ollama's `tools` field."
  @spec specs([String.t()]) :: [map()]
  def specs(names \\ @names), do: Enum.filter(all_specs(), &(&1.function.name in names))

  defp all_specs do
    [
      spec(
        "read",
        "Read a text file in the workspace, or part of it with lines. For Elixir files, " <>
          "outline: true lists its modules and functions with line ranges, and symbol reads just " <>
          "one definition; use them to find code instead of grep. Long tool output is shortened " <>
          "for you; result reads the full output of an earlier tool call (e.g. \"e12\").",
        %{
          path: %{type: "string", description: "path relative to the workspace root"},
          outline: %{
            type: "boolean",
            description: "list the file's modules and functions with their line ranges instead"
          },
          symbol: %{
            type: "string",
            description: ~s(read only this definition, e.g. "init/1", "init" or "MyApp.Mod.init/1")
          },
          lines: %{type: "string", description: ~s(read only these lines, e.g. "120-400")},
          result: %{
            type: "string",
            description: ~s(instead of a file: the full output of an earlier tool call, e.g. "e12")
          }
        },
        []
      ),
      spec("write", "Create or overwrite a file in the workspace with the given content.", %{
        path: %{type: "string", description: "path relative to the workspace root"},
        content: %{type: "string", description: "the complete new file content"}
      }),
      spec(
        "edit",
        "Replace one exact occurrence of old_text with new_text in a workspace file. old_text must match exactly once.",
        %{
          path: %{type: "string", description: "path relative to the workspace root"},
          old_text: %{type: "string", description: "exact text to replace, unique in the file"},
          new_text: %{type: "string", description: "replacement text"}
        }
      ),
      spec(
        "bash",
        "Run a shell command in the workspace root and return its output.",
        %{
          command: %{type: "string", description: "the command line to run with sh -c"},
          timeout_s: %{
            type: "integer",
            description:
              "seconds it may run (default #{@default_bash_timeout_s}, at most #{@max_bash_timeout_s}); " <>
                "set it for builds, test suites and installs"
          }
        },
        ["command"]
      ),
      spec(
        "skill",
        "Load a skill's instructions (SKILL.md), or another file inside that skill's directory.",
        %{
          name: %{type: "string", description: "the skill's name, as listed in the system prompt"},
          file: %{type: "string", description: "optional path relative to the skill directory"}
        },
        ["name"]
      )
    ]
  end

  defp spec(name, description, properties, required \\ nil) do
    required = required || properties |> Map.keys() |> Enum.map(&Atom.to_string/1)

    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: %{
          type: "object",
          properties: properties,
          required: required
        }
      }
    }
  end

  @doc """
  The effect for a tool call in a run with context `ctx` (`:cwd`, optional `:skills`), or
  `{:error, reason}` for an unknown tool, a tool not offered, or bad arguments.
  """
  @spec to_effect(map(), map()) :: {:ok, Effect.t()} | {:error, String.t()}
  def to_effect(%{name: name, arguments: args}, ctx) do
    offered = names_for(ctx)

    case name in offered && effect(name, args, ctx) do
      %Effect{} = effect -> {:ok, effect}
      {:error, reason} -> {:error, reason}
      nil -> {:error, "invalid arguments for #{name}: #{inspect(args)}"}
      false when offered == [] -> {:error, "no tools are available in this turn; answer in text"}
      false -> {:error, "unknown tool #{inspect(name)}; available: #{Enum.join(offered, ", ")}"}
    end
  end

  defp effect("skill", args, ctx), do: skill_effect(args, ctx)
  defp effect(name, args, ctx), do: tool_effect(name, args, cwd: Map.get(ctx, :cwd), reply: :tool_done)

  defp skill_effect(%{"name" => skill} = args, ctx) when is_binary(skill) do
    case Enum.find(Map.get(ctx, :skills, []), &(&1.name == skill)) do
      nil -> {:error, "no skill named #{inspect(skill)}"}
      %{dir: dir} -> Effect.read(args["file"] || "SKILL.md", cwd: dir, reply: :tool_done)
    end
  end

  defp skill_effect(_args, _ctx), do: nil

  # nil for arguments of the wrong shape.
  defp tool_effect("read", args, opts), do: read_effect(args, opts)
  defp tool_effect("write", args, opts), do: write_effect(args, opts)
  defp tool_effect("edit", args, opts), do: edit_effect(args, opts)

  defp tool_effect("bash", %{"command" => c} = args, opts) when is_binary(c),
    do: Effect.bash(c, [timeout: bash_timeout_ms(args["timeout_s"])] ++ opts)

  defp tool_effect(_name, _args, _opts), do: nil

  defp read_effect(%{"result" => r}, opts) when is_binary(r) and r != "", do: Effect.read("", [result: r] ++ opts)
  defp read_effect(%{"path" => p} = args, opts) when is_binary(p), do: Effect.read(p, read_view(args) ++ opts)
  defp read_effect(_args, _opts), do: nil

  # One definition, the outline, or a line range of a file; else the whole file.
  defp read_view(%{"symbol" => s}) when is_binary(s) and s != "", do: [symbol: s]
  defp read_view(%{"outline" => true}), do: [outline: true]
  defp read_view(%{"lines" => l}) when is_binary(l) and l != "", do: [lines: l]
  defp read_view(_args), do: []

  defp write_effect(%{"path" => p, "content" => c}, opts) when is_binary(p) and is_binary(c),
    do: protected(p, opts) || Effect.write(p, c, opts)

  defp write_effect(_args, _opts), do: nil

  defp edit_effect(%{"path" => p, "old_text" => o, "new_text" => n}, opts)
       when is_binary(p) and is_binary(o) and is_binary(n), do: protected(p, opts) || Effect.edit(p, o, n, opts)

  defp edit_effect(_args, _opts), do: nil

  @dependency_reason "holds fetched dependencies or build output: they are not rebuilt from " <>
                       "edited sources and are replaced on the next fetch, so the edit would " <>
                       "never take effect. Change the project's own code instead; if the " <>
                       "dependency itself must change, tell the user and propose a fork or an " <>
                       "upstream patch"

  @protected %{
    "deps" => @dependency_reason,
    "_build" => @dependency_reason,
    "node_modules" => @dependency_reason,
    ".git" => "is git's own data; use git commands through bash instead",
    ".xeito" => "is Xeito's event log; it is written only by Xeito"
  }

  @doc "The workspace's top-level directories no tool writes to (dependencies, build output, git, the log)."
  @spec protected_dirs() :: [String.t()]
  def protected_dirs, do: Map.keys(@protected)

  # `{:error, reason}` if `path` (relative to the workspace) lies in a protected directory.
  defp protected(path, opts) do
    root = Path.expand(Keyword.get(opts, :cwd) || ".")

    case path |> Path.expand(root) |> Path.relative_to(root) |> Path.split() do
      [dir | _] when is_map_key(@protected, dir) ->
        {:error, "refused: #{dir}/ #{Map.fetch!(@protected, dir)}"}

      _ ->
        nil
    end
  end

  @doc "Whether a tool call needs the Risk decision before it runs."
  @spec risky?(map()) :: boolean()
  def risky?(%{name: "bash"}), do: true
  def risky?(_call), do: false

  @doc "The text a tool result is reported to the model as."
  @spec result_text(map()) :: String.t()
  def result_text(result), do: text(result) <> timeout_hint(result)

  defp text(%{shaped: text}) when is_binary(text), do: text
  defp text(%{exit_status: status, output: output}), do: "exit status #{status}\n#{output}"
  defp text(%{ok: true} = result), do: ok_text(result)
  defp text(%{ok: false, error: error}), do: "error: #{format_error(error)}"
  defp text(other), do: inspect(other)

  defp timeout_hint(%{timed_out: true}),
    do: "\nIf it needs longer, run it again with timeout_s (seconds, at most #{@max_bash_timeout_s})."

  defp timeout_hint(_result), do: ""

  defp ok_text(%{content: content}), do: content

  defp ok_text(%{syntax_error: error}),
    do: "ok, applied; but the file no longer parses: #{error}. Fix it before continuing."

  defp ok_text(_result), do: "ok"

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
