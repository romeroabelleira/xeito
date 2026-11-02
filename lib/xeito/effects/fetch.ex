defmodule Xeito.Effects.Fetch do
  @moduledoc """
  Runs a `fetch` effect: one HTTP GET of a URL, its body as Markdown for the model.

    * only `http` and `https` URLs; the policy's `network` must allow the host (`Xeito.Policy`):
      `:forbidden` (the default) refuses every fetch, `:allowed` lets all through, a list of host
      names lets those hosts and their subdomains through
    * at most `max_bytes` of body (default 2 MiB), 30 seconds, redirects followed
    * an HTML page goes through `Xeito.Effects.Fetch.Html`; other text comes as it is; a binary
      body is refused
    * the result is `%{ok: true, content: markdown, url: final_url, status: 200, title: title}`
      or `%{ok: false, error: reason}`; nothing is written to the workspace

  What a fetch returns is public input: it came from outside the box and may carry instructions
  meant for the model, which is why the tool is off unless the policy says otherwise.
  """

  alias Xeito.Effect
  alias Xeito.Effects.Fetch.Html
  alias Xeito.Policy

  @max_bytes 2 * 1024 * 1024
  @timeout 30_000

  @doc "Whether the policy's `network` setting lets `url` be fetched."
  @spec allowed?(String.t(), :forbidden | :allowed | [String.t()]) :: boolean()
  def allowed?(_url, :forbidden), do: false
  def allowed?(url, :allowed), do: http?(url)

  def allowed?(url, hosts) when is_list(hosts) do
    host = URI.parse(url).host || ""
    http?(url) and Enum.any?(hosts, &(host == &1 or String.ends_with?(host, "." <> &1)))
  end

  defp http?(url), do: URI.parse(url).scheme in ["http", "https"]

  @doc "Runs the effect. Options: `:plug` (tests), `:network` (the policy's setting, default the effective policy's)."
  @spec run(Effect.t(), keyword()) :: Effect.file_result()
  def run(%Effect{kind: :fetch, args: %{url: url}}, opts) do
    network = Keyword.get_lazy(opts, :network, fn -> Policy.effective().network end)

    cond do
      not http?(url) -> %{ok: false, error: "only http and https URLs can be fetched"}
      not allowed?(url, network) -> %{ok: false, error: refused(network)}
      true -> get(url, opts)
    end
  end

  defp refused(:forbidden),
    do:
      "the network is off: the policy's network setting is forbidden (config :xeito, :policy, network: :allowed, or a list of hosts)"

  defp refused(hosts), do: "this host is not among the ones the policy allows: #{Enum.join(hosts, ", ")}"

  defp get(url, opts) do
    req =
      [method: :get, url: url, receive_timeout: @timeout, retry: false, max_redirects: 5] ++ Keyword.take(opts, [:plug])

    case Req.request(req) do
      {:ok, %{status: 200} = resp} -> body(url, resp, Keyword.get(opts, :max_bytes, @max_bytes))
      {:ok, %{status: status}} -> %{ok: false, error: "HTTP #{status}"}
      {:error, reason} -> %{ok: false, error: "could not fetch: #{Exception.message(reason)}"}
    end
  rescue
    error -> %{ok: false, error: "could not fetch: #{Exception.message(error)}"}
  end

  defp body(url, resp, max_bytes) do
    raw = raw(resp.body)
    type = resp.headers |> Map.get("content-type", [""]) |> List.first() |> String.downcase()

    cond do
      byte_size(raw) > max_bytes -> %{ok: false, error: "the page is larger than #{max_bytes} bytes"}
      not String.valid?(raw) -> %{ok: false, error: "the body is not text (#{type})"}
      html?(type, raw) -> %{ok: true, content: Html.to_markdown(raw), url: url, status: 200, title: Html.title(raw)}
      true -> %{ok: true, content: String.trim(raw), url: url, status: 200, title: nil}
    end
  end

  # Req decodes JSON bodies; the model gets the text.
  defp raw(body) when is_binary(body), do: body
  defp raw(body), do: JSON.encode!(body)

  defp html?(type, raw), do: String.contains?(type, "html") or String.starts_with?(String.trim_leading(raw), "<")
end
