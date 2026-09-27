defmodule Xeito.Tools do
  @moduledoc """
  The core tools, as in pi: `read`, `write`, `edit`, `bash`. Each tool call a model makes is
  turned into an `Xeito.Effect`, so it is logged, replayable and executed by the policy-checked
  runner, never by the model client.

  * `read` and `write`/`edit` are confined to the workspace by `Xeito.Effects.Local`.
  * `bash` commands pass the `Xeito.Decisions.Risk` decision first (see `Xeito.Machines.Chat`).
  * An unknown tool name or malformed arguments become an error result for the model, not a
    crash: the set of tools is closed, like a typed decision's values.
  """

  alias Xeito.Effect

  @names ~w(read write edit bash)

  @doc "Tool names the model may call."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "OpenAI-style function specs, as accepted by Ollama's `tools` field."
  @spec specs() :: [map()]
  def specs do
    [
      spec("read", "Read a text file in the workspace.", %{
        path: %{type: "string", description: "path relative to the workspace root"}
      }),
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
      spec("bash", "Run a shell command in the workspace root and return its output.", %{
        command: %{type: "string", description: "the command line to run with sh -c"}
      })
    ]
  end

  defp spec(name, description, properties) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: %{
          type: "object",
          properties: properties,
          required: properties |> Map.keys() |> Enum.map(&Atom.to_string/1)
        }
      }
    }
  end

  @doc "The effect for a tool call, or `{:error, reason}` for an unknown tool or bad arguments."
  @spec to_effect(map(), String.t()) :: {:ok, Effect.t()} | {:error, String.t()}
  def to_effect(%{name: name, arguments: args}, cwd) do
    case effect(name, args, cwd: cwd, reply: :tool_done) do
      %Effect{} = effect -> {:ok, effect}
      nil when name in @names -> {:error, "invalid arguments for #{name}: #{inspect(args)}"}
      nil -> {:error, "unknown tool #{inspect(name)}; available: #{Enum.join(@names, ", ")}"}
    end
  end

  defp effect("read", %{"path" => p}, opts) when is_binary(p), do: Effect.read(p, opts)

  defp effect("write", %{"path" => p, "content" => c}, opts) when is_binary(p) and is_binary(c),
    do: Effect.write(p, c, opts)

  defp effect("edit", %{"path" => p, "old_text" => o, "new_text" => n}, opts)
       when is_binary(p) and is_binary(o) and is_binary(n),
       do: Effect.edit(p, o, n, opts)

  defp effect("bash", %{"command" => c}, opts) when is_binary(c), do: Effect.bash(c, opts)
  defp effect(_name, _args, _opts), do: nil

  @doc "Whether a tool call needs the Risk decision before it runs."
  @spec risky?(map()) :: boolean()
  def risky?(%{name: "bash"}), do: true
  def risky?(_call), do: false

  @doc "The text a tool result is reported to the model as."
  @spec result_text(map()) :: String.t()
  def result_text(%{exit_status: status, output: output}),
    do: "exit status #{status}\n#{output}"

  def result_text(%{ok: true, content: content}), do: content
  def result_text(%{ok: true}), do: "ok"
  def result_text(%{ok: false, error: error}), do: "error: #{format_error(error)}"
  def result_text(other), do: inspect(other)

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
