defmodule Xeito.Effects.Fetch.Html do
  @moduledoc """
  Turns a web page into Markdown for the model: the readability pass of the `fetch` tool.

    * `<head>`, `<script>`, `<style>`, `<noscript>`, `<svg>`, `<nav>`, `<header>`, `<footer>` and `<aside>`
      are dropped with their contents; `<main>` or `<article>`, when the page has one, is all that
      is kept
    * headings become `#` lines, paragraphs and `<br>` line breaks, list items `- ` lines, `<pre>`
      fenced code, `<code>` backticks, and a link its text followed by its URL in parentheses
    * every other tag is removed and its text kept; entities are decoded; blank lines are collapsed

  It is a text pass with regular expressions, not an HTML parser: good enough for documentation
  and articles, and it never raises.
  """

  @dropped ~w(head script style noscript svg nav header footer aside template iframe)

  @doc "The page's title, if it has one."
  @spec title(String.t()) :: String.t() | nil
  def title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html) do
      [_, title] -> title |> strip_tags() |> decode() |> squeeze()
      nil -> nil
    end
  end

  @doc "The page as Markdown."
  @spec to_markdown(String.t()) :: String.t()
  def to_markdown(html) do
    html
    |> main()
    |> drop(@dropped)
    |> blocks()
    |> strip_tags()
    |> decode()
    |> tidy()
  end

  # The main content, when the page marks it.
  defp main(html) do
    case Regex.run(~r/<(main|article)\b[^>]*>(.*)<\/\1>/is, html) do
      [_, _tag, inner] -> inner
      nil -> html
    end
  end

  defp drop(html, tags) do
    Enum.reduce(tags, html, fn tag, acc -> Regex.replace(~r/<#{tag}\b[^>]*>.*?<\/#{tag}>/is, acc, "") end)
  end

  # Block structure as Markdown, before the remaining tags go.
  defp blocks(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<pre\b[^>]*>(.*?)<\/pre>/is, fn pre ->
      [_, code] = Regex.run(~r/<pre\b[^>]*>(.*?)<\/pre>/is, pre)
      "\n```\n" <> (code |> strip_tags() |> decode() |> String.trim("\n")) <> "\n```\n"
    end)
    |> String.replace(~r/<h([1-6])\b[^>]*>(.*?)<\/h\1>/is, fn heading ->
      [_, level, text] = Regex.run(~r/<h([1-6])\b[^>]*>(.*?)<\/h\1>/is, heading)
      "\n\n" <> String.duplicate("#", String.to_integer(level)) <> " " <> squeeze(strip_tags(text)) <> "\n\n"
    end)
    |> String.replace(~r/<a\b[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/is, fn link ->
      [_, href, text] = Regex.run(~r/<a\b[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/is, link)
      text = squeeze(strip_tags(text))
      if text == "" or String.starts_with?(href, "#"), do: text, else: "#{text} (#{href})"
    end)
    |> String.replace(~r/<code\b[^>]*>(.*?)<\/code>/is, "`\\1`")
    |> String.replace(~r/<li\b[^>]*>/i, "\n- ")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/?(p|div|section|ul|ol|table|tr|blockquote|dl|dd|dt|figure|h[1-6])\b[^>]*>/i, "\n\n")
    |> String.replace(~r/<\/(td|th)>/i, " | ")
  end

  defp strip_tags(text), do: Regex.replace(~r/<[^>]+>/, text, "")

  @entities %{"amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "nbsp" => " ", "#39" => "'"}

  defp decode(text) do
    Regex.replace(~r/&(#x?[0-9a-fA-F]+|[a-zA-Z0-9]+);/, text, fn whole, name -> entity(whole, name) end)
  end

  defp entity(_whole, "#x" <> hex), do: codepoint(Integer.parse(hex, 16))
  defp entity(_whole, "#" <> dec), do: codepoint(Integer.parse(dec, 10))
  defp entity(whole, name), do: Map.get(@entities, name, whole)

  defp codepoint({n, ""}) when n > 0 and n < 0x110000, do: <<n::utf8>>
  defp codepoint(_other), do: ""

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # Lines trimmed, runs of blank lines collapsed, the whole trimmed.
  defp tidy(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim/1)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
