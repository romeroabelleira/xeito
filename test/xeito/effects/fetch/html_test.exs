defmodule Xeito.Effects.Fetch.HtmlTest do
  use ExUnit.Case, async: true

  alias Xeito.Effects.Fetch.Html

  test "headings, paragraphs, lists, links, code and entities become Markdown; boilerplate goes" do
    html = """
    <html><head><title> Docs &amp; Notes </title><style>p{}</style><script>x()</script></head>
    <body><nav><a href="/">Home</a></nav>
    <h1>Title</h1><p>First &lt;p&gt;.<br>Second line.</p>
    <ul><li>one</li><li>two with <a href="https://x.test/a">a link</a> and <a href="#top">top</a></li></ul>
    <pre><code>def f, do: 1
    </code></pre><p>Use <code>mix ci</code>.</p>
    <footer>© 2026</footer></body></html>
    """

    assert Html.title(html) == "Docs & Notes"

    assert Html.to_markdown(html) ==
             "# Title\n\nFirst <p>.\nSecond line.\n\n- one\n- two with a link (https://x.test/a) and top\n\n" <>
               "```\ndef f, do: 1\n```\n\nUse `mix ci`."
  end

  test "a page with a main element keeps that alone" do
    html = "<body><header>Site</header><main><h2>Here</h2><p>Body.</p></main><aside>Ads</aside></body>"
    assert Html.to_markdown(html) == "## Here\n\nBody."
  end

  test "numeric entities are decoded, unknown ones kept; no title is nil" do
    assert Html.to_markdown("<p>&#169; &#x41; &zzz;</p>") == "© A &zzz;"
    assert Html.title("<p>no title</p>") == nil
  end

  test "text without any tags comes back trimmed" do
    assert Html.to_markdown("  plain\n\n\n\ntext  ") == "plain\n\ntext"
  end
end
